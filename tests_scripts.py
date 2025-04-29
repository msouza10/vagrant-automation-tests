#!/usr/bin/env python3
import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)
logger = logging.getLogger(__name__)


def run_cmd(cmd: str, cwd: Path | None = None, debug: bool = False, prefix: str = "") -> tuple[int, str]:
    """
    Executa um comando via shell (shell=True) e retorna (returncode, stdout).
    Mantém shell=True para permitir execução com privilégios de root.
    """
    env = os.environ.copy()
    if debug:
        env["VAGRANT_LOG"] = "debug"
    logger.debug("%s Executando: %s", prefix, cmd)
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
    )
    output_lines = []
    try:
        for line in proc.stdout:
            msg = f"{prefix} {line.strip()}" if prefix else line.strip()
            logger.info(msg)
            output_lines.append(msg + "\n")
        proc.wait(timeout=600)
    except subprocess.TimeoutExpired:
        proc.kill()
        logger.error("%s Timeout ao executar comando.", prefix)
        return -1, ''.join(output_lines)

    return proc.returncode, ''.join(output_lines)


class Workspace:
    """
    Representa o diretório de trabalho para teste de uma VM.
    Copia o script e o provision_path para o workdir.
    """
    def __init__(
        self,
        box: str,
        script: Path,
        provision_path: Path | None,
        script_args: list[str],
        cleanup: bool,
    ):
        self.box = box
        self.script = script
        self.provision_path = provision_path
        self.script_args = script_args
        self.cleanup = cleanup
        self.dir = Path(tempfile.mkdtemp(prefix="vg-test-"))
        self.logs_dir = self.dir / "logs"
        self.logs_dir.mkdir(exist_ok=True)
        # Copia o script para o workdir
        dest_script = self.dir / self.script.name
        shutil.copy(self.script, dest_script)
        dest_script.chmod(dest_script.stat().st_mode | 0o111)
        # Copia o provision_path se existir
        if self.provision_path:
            dest_prov = self.dir / self.provision_path.name
            shutil.copy(self.provision_path, dest_prov)
            dest_prov.chmod(dest_prov.stat().st_mode | 0o111)
        logger.info("[%s] Workspace criado em %s", box, self.dir)

    def write_vagrantfile(self, provisioner: str | None) -> None:
        vfile = self.dir / "Vagrantfile"
        lines = [
            'Vagrant.configure("2") do |config|',
            f'  config.vm.box = "{self.box}"',
            '  config.vm.synced_folder ".", "/vagrant", disabled: false',
        ]
        if provisioner and self.provision_path:
            args_json = json.dumps(self.script_args)
            if provisioner == 'shell':
                lines.append(
                    f'  config.vm.provision "shell", privileged: true, path: "{self.provision_path.name}", args: {args_json}'
                )
            elif provisioner == 'ansible':
                lines.extend([
                    '  config.vm.provision "ansible" do |ansible|',
                    '    ansible.become = true',
                    f'    ansible.playbook = "{self.provision_path.name}"',
                    '  end',
                ])
        lines.append('end')
        vfile.write_text("\n".join(lines))
        logger.debug("[%s] Vagrantfile escrito.", self.box)

    def cleanup_workspace(self) -> None:
        if self.cleanup and self.dir.exists():
            shutil.rmtree(self.dir)
            logger.info("[%s] Workspace %s removido.", self.box, self.dir)


class VagrantManager:
    def __init__(self, workspace: Workspace, provider: str, debug: bool):
        self.ws = workspace
        self.provider = provider
        self.debug = debug

    def up(self, provisioner: str | None) -> None:
        prefix = f"[{self.ws.box}]"
        try:
            self.ws.write_vagrantfile(provisioner)
            cmd = f"vagrant up --provider {self.provider}"
            if self.debug:
                cmd = f"vagrant up --debug --provider {self.provider}"

            logger.info("%s Levantando VM...", prefix)
            code, out = run_cmd(cmd, cwd=self.ws.dir, debug=self.debug, prefix=prefix)
            (self.ws.logs_dir / f"{self.ws.box}_up.log").write_text(out)

            if code != 0 and ("E_INVALIDARG" in out or "VBoxManage" in out):
                logger.warning("%s Erro de import. Removendo e readicionando box...", prefix)
                run_cmd(f"vagrant box remove {self.ws.box} --all --force", cwd=self.ws.dir, debug=self.debug, prefix=prefix)
                run_cmd(f"vagrant box add {self.ws.box} --provider {self.provider} --force", cwd=self.ws.dir, debug=self.debug, prefix=prefix)
                logger.info("%s Retentando 'vagrant up'...", prefix)
                code, out = run_cmd(cmd, cwd=self.ws.dir, debug=self.debug, prefix=prefix)
                (self.ws.logs_dir / f"{self.ws.box}_up_retry.log").write_text(out)

            if code != 0:
                logger.error("%s Falha ao subir VM '%s' (código %d).", prefix, self.ws.box, code)
                return

            if not provisioner:
                args_str = " " + " ".join(self.ws.script_args) if self.ws.script_args else ""
                ssh_cmd = f"vagrant ssh -c \"sudo bash /vagrant/{self.ws.script.name}{args_str}\""
                logger.info("%s Executando script via SSH...", prefix)
                code_s, out_s = run_cmd(ssh_cmd, cwd=self.ws.dir, debug=self.debug, prefix=prefix)
                (self.ws.logs_dir / f"{self.ws.box}_script_output.log").write_text(out_s)
                if not self.debug:
                    logger.info("%s OUTPUT:\n%s", prefix, out_s)

            logger.info("%s Para destruir: python %s destroy --workdir %s", prefix, Path(sys.argv[0]).name, self.ws.dir)

        except Exception:
            logger.error("%s Erro durante 'up':", prefix)
            traceback.print_exc()
        finally:
            self.ws.cleanup_workspace()

    def destroy(self) -> None:
        prefix = "[destroy]"
        path = Path(self.ws.dir)
        if not path.exists():
            logger.error("Workdir '%s' não encontrado.", self.ws.dir)
            return
        try:
            cmd = "vagrant destroy -f"
            if self.debug:
                cmd = "vagrant destroy --debug -f"
            logger.info("%s Destruindo VM em %s", prefix, self.ws.dir)
            code, out = run_cmd(cmd, cwd=self.ws.dir, debug=self.debug, prefix=prefix)
            (path / "logs" / "destroy.log").write_text(out)
        except Exception:
            logger.error("%s Erro durante 'destroy':", prefix)
            traceback.print_exc()


def main():
    if shutil.which("vagrant") is None:
        logger.error("Vagrant não encontrado.")
        sys.exit(1)

    parser = argparse.ArgumentParser(description="Testa scripts em múltiplas VMs via Vagrant.")
    subparsers = parser.add_subparsers(dest="action", required=True)

    up_parser = subparsers.add_parser("up", help="Cria/testa VMs.")
    up_parser.add_argument("script", type=Path, help="Script a ser testado.")
    up_parser.add_argument("--box", help="Nome da box.")
    up_parser.add_argument("--boxes", type=Path, help="Arquivo com lista de boxes.")
    up_parser.add_argument("--provider", default="virtualbox", help="Provider Vagrant.")
    up_parser.add_argument("--provisioner", choices=["shell", "ansible"], help="Tipo de provisioner.")
    up_parser.add_argument("--provision-path", type=Path, help="Caminho do provisionamento.")
    up_parser.add_argument("--parallel", type=int, default=1, help="Número de VMs paralelas.")
    up_parser.add_argument("--cleanup", action="store_true", help="Remove workdir após execução.")
    up_parser.add_argument("--debug", action="store_true", help="Ativa modo debug.")

    destroy_parser = subparsers.add_parser("destroy", help="Apaga VM.")
    destroy_parser.add_argument("--workdir", required=True, help="Pasta workdir para destruir.")
    destroy_parser.add_argument("--debug", action="store_true", help="Ativa modo debug.")

    # parse known args to capture any extra flags for o script
    args, unknown = parser.parse_known_args()

    if args.action == "up":
        if not args.script.exists():
            logger.error("Script inválido: %s", args.script)
            sys.exit(1)

        boxes = []
        if args.boxes:
            if not args.boxes.exists():
                logger.error("Arquivo não encontrado: %s", args.boxes)
                sys.exit(1)
            boxes = [line.strip() for line in args.boxes.read_text().splitlines() if line.strip()]
        elif args.box:
            boxes = [args.box]
        else:
            logger.error("Informe --box ou --boxes.")
            sys.exit(1)

        # any extra argument goes to the script
        script_args = unknown

        def worker(box_name: str):
            ws = Workspace(box_name, args.script, args.provision_path, script_args, args.cleanup)
            mgr = VagrantManager(ws, args.provider, args.debug)
            mgr.up(args.provisioner)

        if args.parallel > 1:
            with ThreadPoolExecutor(max_workers=args.parallel) as executor:
                for _ in executor.map(worker, boxes):
                    pass
        else:
            for box_name in boxes:
                worker(box_name)

    elif args.action == "destroy":
        ws = Workspace("destroy", Path(), None, [], False)
        ws.dir = Path(args.workdir)
        mgr = VagrantManager(ws, "", args.debug)
        mgr.destroy()


if __name__ == "__main__":
    main()
