---
layout: default
title: Ansible 基礎速查
parent: Infra / DevOps
nav_order: 5
---

# Ansible 基礎速查
{: .no_toc }

從環境配置到執行 Playbook 的概念流程
{: .fs-6 .fw-300 }

## 目錄
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、Ansible 是什麼

Ansible 是一套**agentless**的自動化工具，透過 SSH 對遠端機器下指令，不需要在被控機器上安裝任何 agent。

| 核心特性 | 說明 |
|:---------|:-----|
| **Agentless** | 被控機器不需安裝 Ansible，只需有 SSH + Python |
| **SSH-based** | 控制節點透過 SSH 連線到被控節點執行任務 |
| **Idempotent** | 同一個 Playbook 執行多次，結果一致，不會重複副作用 |

---

## 二、環境準備

### 角色定義

```
Control Node（你的機器）  ──SSH──▶  Managed Node（被管理的機器）
  - 安裝 Ansible               - 只需 SSH + Python
  - 存放 Inventory / Playbook
```

### 安裝 Ansible（Control Node）

```bash
# macOS
brew install ansible

# Ubuntu/Debian
sudo apt install ansible
```

### 設定 SSH Key-based 認證

Ansible 預設用 SSH 金鑰連線，**不建議用密碼**（每次都要輸入，且不適合自動化）。

```bash
# 1. 在 control node 產生 key pair（如果還沒有）
ssh-keygen -t ed25519

# 2. 把公鑰推到 managed node
ssh-copy-id user@192.168.1.10

# 3. 確認可以無密碼登入
ssh user@192.168.1.10
```

### 驗證連線

```bash
# Ansible 的 ping（不是 ICMP，而是測試 SSH + Python 是否正常）
ansible all -i "192.168.1.10," -m ping -u user
```

---

## 三、Inventory

### 概念

Inventory 告訴 Ansible **要管理哪些機器**，以及如何將它們分群。

### 靜態 Inventory（INI 格式）

```ini
# inventory.ini

[webservers]
web1 ansible_host=192.168.1.10
web2 ansible_host=192.168.1.11

[dbservers]
db1 ansible_host=192.168.1.20

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

### 靜態 Inventory（YAML 格式）

```yaml
# inventory.yaml
all:
  children:
    webservers:
      hosts:
        web1:
          ansible_host: 192.168.1.10
        web2:
          ansible_host: 192.168.1.11
    dbservers:
      hosts:
        db1:
          ansible_host: 192.168.1.20
  vars:
    ansible_user: ubuntu
```

### 常用群組

| 群組名 | 說明 |
|:-------|:-----|
| `all` | 所有機器的預設群組，永遠存在 |
| `ungrouped` | 沒有被分配群組的機器 |
| 自訂群組 | 如 `webservers`、`dbservers` |

---

## 四、Ad-hoc 指令

### 概念

Ad-hoc 是**一次性指令**，適合快速對機器執行單一操作，不需要寫 Playbook。

```bash
ansible <目標> -i <inventory> -m <module> -a "<參數>"
```

### 常用範例

```bash
# 測試連線
ansible all -i inventory.ini -m ping

# 在所有機器上執行指令
ansible all -i inventory.ini -m command -a "uptime"

# 只對 webservers 群組執行
ansible webservers -i inventory.ini -m command -a "df -h"

# 複製檔案到遠端
ansible all -i inventory.ini -m copy -a "src=./hello.txt dest=/tmp/hello.txt"

# 安裝套件（需要 sudo）
ansible all -i inventory.ini -m apt -a "name=nginx state=present" --become
```

> `--become` 等同於 sudo，對需要權限的操作必須加上。

---

## 五、Playbook

### 概念

Playbook 是用 YAML 寫的**可重複執行劇本**，描述「對哪些機器、按順序做哪些事」。

```
Playbook
└── Play（針對哪些主機）
    └── Tasks（依序執行的任務，每個任務呼叫一個 Module）
```

### 一個完整的 Playbook 範例

```yaml
# deploy_nginx.yaml
---
- name: 安裝並啟動 Nginx
  hosts: webservers
  become: true

  tasks:
    - name: 安裝 nginx
      apt:
        name: nginx
        state: present
        update_cache: true

    - name: 確保 nginx 服務啟動
      service:
        name: nginx
        state: started
        enabled: true

    - name: 複製設定檔
      copy:
        src: ./nginx.conf
        dest: /etc/nginx/nginx.conf
      notify: restart nginx

  handlers:
    - name: restart nginx
      service:
        name: nginx
        state: restarted
```

### 執行 Playbook

```bash
# 基本執行
ansible-playbook -i inventory.ini deploy_nginx.yaml

# 先預覽會做什麼（dry run）
ansible-playbook -i inventory.ini deploy_nginx.yaml --check

# 只對特定主機執行
ansible-playbook -i inventory.ini deploy_nginx.yaml --limit web1
```

---

## 六、常用 Module 速查

| Module | 用途 | 範例 |
|:-------|:-----|:-----|
| `command` | 執行指令（不走 shell，不支援管線） | `command: uptime` |
| `shell` | 執行 shell 指令（支援管線、重導向） | `shell: cat /etc/os-release \| grep NAME` |
| `copy` | 複製本地檔案到遠端 | `copy: src=./app.conf dest=/etc/app.conf` |
| `file` | 管理檔案 / 目錄 / 權限 | `file: path=/tmp/logs state=directory mode=0755` |
| `apt` | 管理 Debian/Ubuntu 套件 | `apt: name=git state=present` |
| `yum` | 管理 RHEL/CentOS 套件 | `yum: name=git state=present` |
| `service` | 管理系統服務 | `service: name=nginx state=started enabled=true` |
| `template` | 渲染 Jinja2 模板後複製到遠端 | `template: src=app.conf.j2 dest=/etc/app.conf` |
| `ping` | 測試 Ansible 連線與 Python 環境 | `ping:` |

---

## 七、常見觀念釐清

| 問題 | 答案 |
|:-----|:-----|
| Managed node 要裝 Ansible 嗎？ | 不用，只需要 SSH 和 Python |
| `command` 和 `shell` 的差別？ | `command` 更安全（不走 shell），`shell` 才支援 `\|`、`>`、`&&` |
| 為什麼要用 SSH key？ | 自動化不能每次輸入密碼；key 也更安全 |
| Idempotent 是什麼意思？ | 執行一次和執行十次的結果相同，不會重複建立或破壞狀態 |
| `--become` 是什麼？ | 提權，等同於 `sudo`，執行需要 root 權限的任務時使用 |

---

## 八、Roles

### 概念

當 Playbook 越來越大，把所有 tasks 寫在同一個檔案會難以維護。Role 是把任務拆成**獨立模組**的方式，每個 role 負責一件事（安裝 Docker、設定 Jenkins、安裝 cloudflared）。

```
Playbook (site.yml)
├── role: docker       → roles/docker/tasks/main.yml
├── role: jenkins      → roles/jenkins/tasks/main.yml
└── role: cloudflared  → roles/cloudflared/tasks/main.yml
```

### 目錄結構

```
roles/
└── cloudflared/
    └── tasks/
        └── main.yml    # 這個 role 的所有任務
```

Ansible 會自動找 `roles/<name>/tasks/main.yml`，不需要手動 include。

### site.yml 怎麼使用 Role

```yaml
- name: Configure Jenkins Controller
  hosts: jenkins
  become: true

  roles:
    - docker       # 依序執行
    - jenkins
    - cloudflared
```

roles 是**依序執行**的，前一個跑完才跑下一個。

### 執行

```bash
# 執行整個 playbook
ansible-playbook -i inventory.ini site.yml

# 只執行特定 role（用 tags，進階用法）
ansible-playbook -i inventory.ini site.yml --tags cloudflared
```

---

## 九、Variables 與 group_vars

### 概念

變數讓你避免把值寫死在 tasks 裡，改由統一的地方管理。

### group_vars/all.yml

`group_vars/all.yml` 是 Ansible 的**慣例目錄**，放在這裡的變數會自動套用到所有 host，不需要手動載入。

```
ansible/
├── group_vars/
│   └── all.yml       ← 自動載入，所有 host 都能用
├── inventory.ini
└── site.yml
```

```yaml
# group_vars/all.yml
jenkins_image: "jenkins/jenkins:2.541.3-lts"
jenkins_data_dir: "/mnt/jenkins-data"
aws_region: "ap-northeast-1"
cloudflare_ssm_param: "/jenkins/cloudflare-tunnel-token"
```

在 tasks 裡直接用 `{{ 變數名 }}` 引用：

```yaml
- name: Pull Jenkins image
  command: docker pull {{ jenkins_image }}
```

### 變數優先順序（常見的幾層）

```
extra vars (-e)          ← 最高優先（執行時手動傳入）
task vars
group_vars/all.yml
role defaults            ← 最低優先
```

---

## 十、ansible.cfg

專案層級的 Ansible 設定檔，放在 playbook 同目錄，執行時自動載入。

```ini
[defaults]
inventory = inventory.ini          # 預設 inventory，不用每次加 -i
remote_user = ec2-user             # SSH 登入的使用者
private_key_file = ~/.ssh/jenkins-key  # SSH 私鑰路徑
host_key_checking = False          # 第一次連新機器不用手動確認 fingerprint
```

設定好後執行指令可以簡化：

```bash
# 沒有 ansible.cfg
ansible-playbook -i inventory.ini -u ec2-user --private-key ~/.ssh/jenkins-key site.yml

# 有 ansible.cfg
ansible-playbook site.yml
```

---

## 十一、Task 進階控制

### register — 儲存指令結果

把 task 的執行結果存成變數，後續 task 可以引用。

```yaml
- name: Get token from SSM
  command: aws ssm get-parameter --name "/jenkins/token" --with-decryption --query "Parameter.Value" --output text
  register: tunnel_token      # 結果存到 tunnel_token 變數

- name: Install cloudflared service
  command: cloudflared service install {{ tunnel_token.stdout }}
  #                                              ↑ 取指令的標準輸出
```

`register` 結果常用的欄位：

| 欄位 | 說明 |
|------|------|
| `.stdout` | 指令的標準輸出（字串）|
| `.stderr` | 標準錯誤輸出 |
| `.rc` | return code（0 = 成功）|

### changed_when — 控制「是否算有變更」

Ansible 每個 task 執行後會回報 `changed` 或 `ok`。`command` / `shell` module 因為 Ansible 無法判斷有沒有真正改變什麼，預設永遠回報 `changed`。

用 `changed_when: false` 告訴 Ansible 這個 task 永遠不算有變更（唯讀操作適用）：

```yaml
- name: Get token from SSM
  command: aws ssm get-parameter ...
  register: tunnel_token
  changed_when: false    # 只是讀資料，不算變更
```

### no_log — 隱藏敏感資料

預設 Ansible 會把 task 的輸入輸出印在 log 裡。如果 task 涉及 token、密碼，加上 `no_log: true` 避免洩漏：

```yaml
- name: Get Cloudflare Tunnel token from SSM
  command: aws ssm get-parameter --with-decryption ...
  register: tunnel_token
  changed_when: false
  no_log: true    # token 不會出現在 log 裡
```

### args.creates — 讓 task 有 idempotent 效果

`command` / `shell` module 本身不是 idempotent，但可以用 `creates` 指定「如果這個檔案存在就跳過」：

```yaml
- name: Install cloudflared as systemd service
  command: cloudflared service install {{ tunnel_token.stdout }}
  args:
    creates: /etc/systemd/system/cloudflared.service
    # ↑ 如果這個檔案已存在，跳過這個 task
```

---

## 十二、Ansible Vault（Secret 管理）

### 概念

Vault 是 Ansible 內建的加密機制，用來**保護敏感資料**（密碼、token、API key），讓它們可以安全地提交進 git。

### 加密單一變數（inline）

```bash
# 產生加密字串，貼進 vars 檔
ansible-vault encrypt_string 'my-secret-token' --name 'db_password'
```

輸出結果直接貼進 `group_vars/all.yml`：

```yaml
db_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  61383462343866343933386436383637...
```

### 加密整個檔案

```bash
# 加密
ansible-vault encrypt group_vars/prod/secrets.yml

# 編輯加密檔
ansible-vault edit group_vars/prod/secrets.yml

# 解密（會覆蓋原檔，謹慎使用）
ansible-vault decrypt group_vars/prod/secrets.yml

# 檢視內容但不解密
ansible-vault view group_vars/prod/secrets.yml
```

### 執行時解密

```bash
# 互動輸入密碼
ansible-playbook site.yml --ask-vault-pass

# 從密碼檔讀取（CI/CD 常用）
ansible-playbook site.yml --vault-password-file ~/.vault_pass
```

> Prod 建議：密碼檔路徑加進 `.gitignore`，不要提交進 git。

---

## 十三、when — 條件執行

```yaml
- name: 只在 Ubuntu 上安裝 apt 套件
  apt:
    name: nginx
    state: present
  when: ansible_os_family == "Debian"

- name: 只在非 prod 環境執行
  command: /opt/run-seed.sh
  when: env != "production"

# 多條件（and）
- name: 滿足兩個條件才執行
  command: /opt/migrate.sh
  when:
    - ansible_os_family == "Debian"
    - app_version is defined
```

常用的內建變數（`ansible_facts`）：

| 變數 | 說明 |
|------|------|
| `ansible_os_family` | `Debian` / `RedHat` |
| `ansible_distribution` | `Ubuntu` / `CentOS` |
| `ansible_distribution_version` | `22.04` |
| `ansible_hostname` | 機器 hostname |

---

## 十四、loop — 迴圈

### 基本用法

```yaml
- name: 建立多個使用者
  user:
    name: "{{ item }}"
    state: present
  loop:
    - alice
    - bob
    - carol
```

### loop + dict

```yaml
- name: 安裝多個套件並指定版本
  apt:
    name: "{{ item.name }}"
    state: "{{ item.state }}"
  loop:
    - { name: nginx,   state: present }
    - { name: apache2, state: absent  }
```

### loop + register

```yaml
- name: 檢查多個服務狀態
  command: systemctl is-active {{ item }}
  register: service_status
  loop:
    - nginx
    - docker
  changed_when: false

- name: 印出結果
  debug:
    msg: "{{ item.item }}: {{ item.stdout }}"
  loop: "{{ service_status.results }}"
```

---

## 十五、block / rescue / always — 錯誤處理

類似程式語言的 `try / catch / finally`，用來控制 task 失敗時的行為。

```yaml
- name: 部署應用程式
  block:
    - name: 停止服務
      service:
        name: myapp
        state: stopped

    - name: 部署新版本
      copy:
        src: ./myapp
        dest: /opt/myapp

    - name: 啟動服務
      service:
        name: myapp
        state: started

  rescue:
    # block 裡任何一個 task 失敗，執行這裡
    - name: 部署失敗，回滾舊版本
      copy:
        src: ./myapp.bak
        dest: /opt/myapp

  always:
    # 不管成功或失敗，都執行這裡
    - name: 發送部署通知
      slack:
        msg: "Deploy finished on {{ inventory_hostname }}"
```

---

## 十六、Tags — 選擇性執行

### 設定 tags

```yaml
- name: 安裝 nginx
  apt:
    name: nginx
    state: present
  tags:
    - install
    - nginx

- name: 更新設定
  template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
  tags:
    - config
    - nginx
```

### 執行時指定 tags

```bash
# 只執行有 config tag 的 tasks
ansible-playbook site.yml --tags config

# 跳過 install tag 的 tasks
ansible-playbook site.yml --skip-tags install

# 列出所有 tasks 和它們的 tags（不執行）
ansible-playbook site.yml --list-tasks
```

> Prod 常見用法：`--tags config` 只更新設定、`--tags deploy` 只跑部署流程，不重跑安裝步驟。

---

## 十七、Rolling Deployment — serial

預設 Ansible 是**同時對所有 host 執行**。在 prod 更新時，可以用 `serial` 控制每批更新幾台，避免全部同時 down。

```yaml
- name: 滾動更新 web 服務
  hosts: webservers
  serial: 1          # 一次只更新一台
  # serial: "25%"    # 或一次更新 25%

  tasks:
    - name: 停止服務
      service:
        name: myapp
        state: stopped

    - name: 部署新版本
      copy:
        src: ./myapp
        dest: /opt/myapp

    - name: 啟動服務
      service:
        name: myapp
        state: started
```

### max_fail_percentage — 失敗門檻

```yaml
- hosts: webservers
  serial: "25%"
  max_fail_percentage: 10   # 超過 10% 的 host 失敗就中止整個 play
```

---

## 十八、Prod 效能調教（ansible.cfg）

```ini
[defaults]
inventory          = inventory.ini
remote_user        = ec2-user
private_key_file   = ~/.ssh/jenkins-key
host_key_checking  = False
forks              = 20        # 同時連線的 host 數（預設 5，prod 可調高）

[ssh_connection]
pipelining         = True      # 減少 SSH 連線次數，顯著提升速度
control_path       = /tmp/ansible-ssh-%%h-%%p-%%r
control_path_dir   = /tmp/.ansible/cp
ssh_args           = -o ControlMaster=auto -o ControlPersist=60s
```

| 設定 | 說明 |
|------|------|
| `forks` | 同時對幾台機器執行（預設 5，大型環境可設 20-50）|
| `pipelining` | 把多個 SSH 指令合併，減少來回次數，速度提升明顯 |
| `ControlPersist` | SSH 連線保持 60 秒，避免每個 task 都重新建連線 |

> 注意：`pipelining = True` 需要 managed node 的 sudoers 關閉 `requiretty`，否則 `--become` 會失敗。

---

## 十九、安全審查變更（--check / --diff）

```bash
# dry run：不實際執行，模擬會做什麼
ansible-playbook site.yml --check

# diff：顯示檔案會有哪些變更（類似 git diff）
ansible-playbook site.yml --diff

# 兩個合用：最安全的事前確認方式
ansible-playbook site.yml --check --diff
```

Prod 部署流程建議：

```
1. ansible-playbook site.yml --check --diff   # 先確認變更內容
2. ansible-playbook site.yml                   # 確認無誤再實際執行
```
