
## 📌 Visão geral

Este script foi criado para automatizar a validação de scripts de provisionamento (como `bash`, `playbooks Ansible`, etc) em diferentes sistemas operacionais ou versões usando **Vagrant**.

É útil para:

- Validar scripts de instalação em várias distros.
- Testar idempotência de playbooks.
- Verificar compatibilidade com diferentes `boxes` Vagrant.
- Simular execuções paralelas em ambientes distintos.

---

## 🛠️ Requisitos

- Python 3.10+
- [Vagrant](https://www.vagrantup.com/)
- Um provider (VirtualBox, libvirt, etc.)
- (Opcional) Ansible, se usar como provisioner

---

## 🚀 Como usar

### 1. Execução simples com uma box

```bash
python3 vagrant_test.py up script.sh --box debian/bookworm64 --cleanup
````

### 2. Usando múltiplas boxes via arquivo

Crie um arquivo `boxes.txt`:

```
debian/bookworm64
ubuntu/focal64
rockylinux/9
```

Execute com:

```bash
python3 vagrant_test.py up script.sh --boxes boxes.txt --cleanup
```

### 3. Usando provisionamento automático

#### a) Provisionamento por Shell

```bash
python3 vagrant_test.py up script.sh --box ubuntu/focal64 \
  --provisioner shell --provision-path provision.sh --cleanup
```

#### b) Provisionamento com Ansible

```bash
python3 vagrant_test.py up script.sh --box debian/bookworm64 \
  --provisioner ansible --provision-path playbook.yml --cleanup
```

---

## ⚙️ Opções avançadas

| Flag               | Descrição                                                            |
| ------------------ | -------------------------------------------------------------------- |
| `--provider`       | Define o provider do Vagrant (padrão: `virtualbox`)                  |
| `--parallel`       | Número de VMs em paralelo                                            |
| `--debug`          | Ativa modo debug do Vagrant                                          |
| `--workdir`        | Define diretório de trabalho fixo (senão usa `/tmp`)                 |
| `--cleanup`        | Destroi VM e remove workdir após execução                            |
| `--script`         | Caminho para o script a ser testado (executado dentro da VM)         |
| `--provision-path` | Caminho para o script ou playbook a ser usado no `vagrant provision` |

---

## 🧹 Limpeza manual

Caso não tenha usado `--cleanup`, é possível destruir e remover workdir manualmente:

```bash
python3 vagrant_test.py destroy --workdir /caminho/do/workdir
```

---

## 🗃️ Estrutura dos logs

Cada workspace gerado contém:

```
workspace/
├── Vagrantfile
├── script.sh
├── provision.sh / playbook.yml
└── logs/
    ├── ubuntu_focal64_up.log
    ├── ubuntu_focal64_script_output.log
    └── destroy.log
```

---

## 💡 Exemplos de uso

* Testar um `install.sh` em 5 distros diferentes antes de enviar PR.
* Automatizar execução de scripts de benchmark.
* Validar correção de bugs de provisionamento com log detalhado.
* Criar lab controlado para validar scripts CI/CD localmente.

---

## 📤 Quer contribuir?

Sugestões são bem-vindas. Envie um PR ou abra uma issue.

---

## 🧠 Autor

Marcos Vinicius – [LinkedIn](https://www.linkedin.com/in/marcos-vinicius-3905b1206) | [GitHub](https://github.com/msouza10)

