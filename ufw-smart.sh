#!/usr/bin/env bash

set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

UFW_DEFAULTS="/etc/default/ufw"
SSH_CONN=""

print_ok() {
  echo -e "${GREEN}[OK]${NC} $1" >&2
}

print_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

print_err() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_info() {
  echo -e "${BLUE}[INFO]${NC} $1" >&2
}

pause() {
  echo >&2
  read -rp "Нажми Enter для продолжения..." || true
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# ufw с английской локалью: вывод разбирается скриптом и не должен зависеть от перевода
ufw_c() {
  LC_ALL=C ufw "$@"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# $1 — вопрос, $2 — ответ по умолчанию: y или n
confirm_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer

  read -rp "$prompt" answer || answer=""
  answer="${answer,,}"

  if [[ "$default" == "y" ]]; then
    case "$answer" in
      n|no|н|нет) return 1 ;;
      *) return 0 ;;
    esac
  fi

  case "$answer" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

run_as_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_warn "Скрипт нужно запускать от root. Перезапускаю через sudo..."
    exec sudo bash "$0" "$@"
  fi
}

detect_pkg_manager() {
  if command_exists apt-get; then
    echo "apt"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists yum; then
    echo "yum"
  elif command_exists pacman; then
    echo "pacman"
  elif command_exists zypper; then
    echo "zypper"
  else
    echo "unknown"
  fi
}

install_ufw() {
  local pm
  pm="$(detect_pkg_manager)"

  print_info "Устанавливаю ufw через пакетный менеджер: $pm"

  case "$pm" in
    apt)
      apt-get update
      apt-get install -y ufw
      ;;
    dnf)
      dnf install -y ufw
      systemctl enable --now ufw || true
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y ufw
      systemctl enable --now ufw || true
      ;;
    pacman)
      pacman -Sy --noconfirm ufw
      systemctl enable --now ufw || true
      ;;
    zypper)
      zypper --non-interactive install ufw
      systemctl enable --now ufw || true
      ;;
    *)
      print_err "Не удалось определить пакетный менеджер."
      print_err "Установи ufw вручную и запусти скрипт снова."
      exit 1
      ;;
  esac

  if command_exists ufw; then
    print_ok "ufw установлен."
  else
    print_err "ufw не установлен. Проверь систему вручную."
    exit 1
  fi
}

check_ufw_installed() {
  local answer

  if ! command_exists ufw; then
    print_warn "ufw не установлен."
    read -rp "Установить ufw сейчас? [y/N]: " answer || answer=""

    case "${answer,,}" in
      y|yes|д|да)
        install_ufw
        ;;
      *)
        print_err "Без ufw скрипт продолжить не может."
        exit 1
        ;;
    esac
  else
    print_ok "ufw уже установлен."
  fi
}

# ---------------------------------------------------------------------------
# SSH: определение клиента и порта
# ---------------------------------------------------------------------------

# sudo обычно вычищает SSH_CONNECTION, поэтому ищем его у родительских процессов
find_ssh_connection() {
  local pid="$$"
  local conn
  local ppid

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION"
    return 0
  fi

  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    if [[ -r "/proc/$pid/environ" ]]; then
      conn="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1 || true)"
      if [[ -n "$conn" ]]; then
        echo "$conn"
        return 0
      fi
    fi

    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    pid="$ppid"
  done

  return 0
}

get_ssh_client_ip() {
  local ip=""

  if [[ -n "$SSH_CONN" ]]; then
    ip="$(awk '{print $1}' <<< "$SSH_CONN")"
  fi

  # IPv4-mapped IPv6 (::ffff:1.2.3.4) -> 1.2.3.4
  if [[ "$ip" =~ ^::[fF]{4}:([0-9.]+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
  fi

  echo "$ip"
}

get_ssh_server_port() {
  local p

  if [[ -n "$SSH_CONN" ]]; then
    awk '{print $4}' <<< "$SSH_CONN"
    return
  fi

  if command_exists sshd; then
    p="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
    if [[ -n "$p" ]]; then
      echo "$p"
      return
    fi
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | tail -n1 | awk '{print $2}' || true)"
    if [[ -n "$p" ]]; then
      echo "$p"
      return
    fi
  fi

  echo "22"
}

get_ufw_status_word() {
  ufw_c status | awk 'NR==1 {print tolower($2)}'
}

# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------

is_ipv6_addr() {
  [[ "$1" == *:* ]]
}

get_ipv6_state() {
  local v

  if [[ ! -f "$UFW_DEFAULTS" ]]; then
    echo "unknown"
    return 0
  fi

  v="$(grep -E '^[[:space:]]*IPV6=' "$UFW_DEFAULTS" 2>/dev/null | tail -n1 || true)"
  v="${v#*=}"
  v="${v//\"/}"
  v="${v//\'/}"
  v="$(trim "$v")"
  v="${v,,}"

  case "$v" in
    yes) echo "yes" ;;
    no) echo "no" ;;
    *) echo "unknown" ;;
  esac
}

ipv6_state_label() {
  case "$1" in
    yes) echo "включён" ;;
    no) echo "выключен" ;;
    *) echo "не определён" ;;
  esac
}

has_global_ipv6() {
  command_exists ip || return 1
  [[ -n "$(ip -6 addr show scope global 2>/dev/null || true)" ]]
}

set_ipv6_state() {
  local target="$1"
  local backup

  [[ -f "$UFW_DEFAULTS" ]] || return 1

  backup="$(mktemp "${UFW_DEFAULTS}.bak.$(date +%Y%m%d-%H%M%S).XXXX")" || return 1
  cp -a "$UFW_DEFAULTS" "$backup" || return 1
  print_info "Резервная копия: $backup"

  if grep -Eq '^[[:space:]]*IPV6=' "$UFW_DEFAULTS"; then
    sed -i -E "s/^[[:space:]]*IPV6=.*/IPV6=${target}/" "$UFW_DEFAULTS" || return 1
  else
    echo "IPV6=${target}" >> "$UFW_DEFAULTS" || return 1
  fi

  [[ "$(get_ipv6_state)" == "$target" ]]
}

# Anywhere-правила по портам, у которых нет (v6)-копии. Формат: "to|comment"
find_rules_without_v6() {
  local line to action from comment
  local -A v4=()
  local -A v6=()
  local -a order=()

  while IFS= read -r line; do
    IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"
    [[ -z "$to" ]] && continue

    if [[ "$to" == *" (v6)" ]]; then
      v6["${to% (v6)}"]=1
      continue
    fi

    case "$action" in ALLOW*) ;; *) continue ;; esac
    [[ "$from" == "Anywhere" ]] || continue
    [[ "$to" =~ ^[0-9,:]+(/(tcp|udp))?$ ]] || continue

    if [[ -z "${v4[$to]+x}" ]]; then
      order+=("$to")
    fi
    v4["$to"]="$comment"
  done < <(ufw_c status 2>/dev/null || true)

  for to in "${order[@]}"; do
    if [[ -z "${v6[$to]+x}" ]]; then
      printf '%s|%s\n' "$to" "${v4[$to]}"
    fi
  done
}

sync_ipv6_twins() {
  local item spec comment
  local -a missing=()

  mapfile -t missing < <(find_rules_without_v6)

  if (( ${#missing[@]} == 0 )); then
    print_ok "У всех Anywhere-правил по портам уже есть (v6)-копии."
    return 0
  fi

  echo >&2
  print_warn "Эти Anywhere-правила сейчас работают только для IPv4:"
  for item in "${missing[@]}"; do
    echo "  ${item%%|*}" >&2
  done

  if ! confirm_yes_no "Создать для них (v6)-копии? [Y/n]: " y; then
    print_warn "(v6)-копии не создавались. По IPv6 эти порты будут закрыты."
    return 0
  fi

  for item in "${missing[@]}"; do
    spec="${item%%|*}"
    comment="${item#*|}"
    comment="${comment:-SMART UFW: v6 sync}"

    if ufw allow "$spec" comment "$comment" >/dev/null; then
      print_ok "Добавлена (v6)-копия: $spec"
    else
      print_err "Не удалось добавить (v6)-копию: $spec"
    fi
  done

  reload_ufw
}

manage_ipv6() {
  local state target old choice client_ip ssh_port confirm
  local was_active="no"

  if [[ ! -f "$UFW_DEFAULTS" ]]; then
    print_err "Не найден $UFW_DEFAULTS — не могу управлять IPv6."
    return 0
  fi

  state="$(get_ipv6_state)"
  client_ip="$(get_ssh_client_ip)"
  ssh_port="$(get_ssh_server_port)"

  echo >&2
  print_info "IPv6 в ufw сейчас: $(ipv6_state_label "$state")"
  echo >&2
  echo "1) Включить IPv6 (IPV6=yes)" >&2
  echo "2) Выключить IPv6 (IPV6=no)" >&2
  echo "0) Назад" >&2
  read -rp "Выбор: " choice || return 0

  case "$choice" in
    1) target="yes" ;;
    2) target="no" ;;
    *) return 0 ;;
  esac

  if [[ "$state" == "$target" ]]; then
    print_info "IPv6 в ufw уже $(ipv6_state_label "$target"). Ничего не меняю."
    return 0
  fi

  if [[ "$state" == "unknown" ]]; then
    if [[ "$target" == "yes" ]]; then old="no"; else old="yes"; fi
  else
    old="$state"
  fi

  echo >&2
  if [[ "$target" == "no" ]]; then
    print_warn "С IPV6=no ufw перестаёт управлять ip6tables: входящий IPv6-трафик НЕ фильтруется ufw."

    if has_global_ipv6; then
      print_warn "У сервера есть глобальные IPv6-адреса:"
      ip -6 -br addr show scope global >&2 || true
      print_warn "Всё, что слушает на IPv6, станет доступно снаружи в обход правил ufw."
      print_warn "Выключать IPv6 в ufw имеет смысл, только если IPv6 отключён и на уровне системы."
      read -rp "Точно выключить IPv6 в ufw? Напиши YES: " confirm || return 0

      if [[ "$confirm" != "YES" ]]; then
        print_warn "Отменено."
        return 0
      fi
    else
      print_info "Глобальных IPv6-адресов на сервере не найдено."
      if ! confirm_yes_no "Выключить IPv6 в ufw? [y/N]: " n; then
        print_warn "Отменено."
        return 0
      fi
    fi
  else
    print_info "С IPV6=yes ufw начнёт фильтровать IPv6 по той же политике (deny incoming)."
    print_warn "Правила, добавленные при выключенном IPv6, существуют только для IPv4."
    print_warn "После включения скрипт предложит создать для Anywhere-правил (v6)-копии."
    if ! confirm_yes_no "Включить IPv6 в ufw? [y/N]: " n; then
      print_warn "Отменено."
      return 0
    fi
  fi

  if [[ "$(get_ufw_status_word || true)" == "active" ]]; then
    was_active="yes"
    print_info "Временно выключаю ufw, чтобы применить настройку..."
    ufw --force disable >/dev/null
  fi

  if ! set_ipv6_state "$target"; then
    print_err "Не удалось изменить $UFW_DEFAULTS."
    if [[ "$was_active" == "yes" ]]; then
      ufw --force enable >/dev/null || print_err "ufw НЕ включен! Проверь вручную: ufw enable"
    fi
    return 0
  fi

  print_ok "Записано в $UFW_DEFAULTS: IPV6=$target"

  if [[ "$target" == "yes" && -n "$client_ip" ]] && is_ipv6_addr "$client_ip"; then
    print_warn "Ты подключен по IPv6: $client_ip"
    if confirm_yes_no "Добавить SSH-правило для этого адреса (tcp/$ssh_port)? [Y/n]: " y; then
      if ufw allow from "$client_ip" to any port "$ssh_port" proto tcp comment "SAFE SSH from current IP" >/dev/null; then
        print_ok "Добавлено SSH-правило: $client_ip -> tcp/$ssh_port"
      else
        print_err "Не удалось добавить SSH-правило для $client_ip"
      fi
    fi
  fi

  if [[ "$was_active" == "yes" ]]; then
    if ufw --force enable >/dev/null; then
      print_ok "ufw снова включен, IPv6 $(ipv6_state_label "$target")."
    else
      print_err "ufw не смог включиться с IPV6=$target. Откатываю на IPV6=$old..."
      set_ipv6_state "$old" || true

      if ufw --force enable >/dev/null; then
        print_warn "ufw включен со старой настройкой IPV6=$old."
      else
        print_err "ufw НЕ включен! Проверь вручную: ufw enable"
      fi
      return 0
    fi
  else
    print_info "ufw выключен — настройка вступит в силу при включении."
  fi

  if [[ "$target" == "yes" && "$was_active" == "yes" ]]; then
    sync_ipv6_twins
  fi
}

# ---------------------------------------------------------------------------
# Валидация
# ---------------------------------------------------------------------------

is_valid_ip_or_cidr() {
  local item="$1"

  if command_exists python3; then
    python3 - "$item" >/dev/null 2>&1 <<'PY'
import sys
import ipaddress

value = sys.argv[1]

try:
    ipaddress.ip_network(value, strict=False)
    sys.exit(0)
except ValueError:
    sys.exit(1)
PY
  else
    [[ "$item" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]
  fi
}

ip_in_list() {
  local client_ip="$1"
  shift
  local ip_list=("$@")
  local item

  if [[ -z "$client_ip" ]]; then
    return 1
  fi

  if ! command_exists python3; then
    for item in "${ip_list[@]}"; do
      [[ "$client_ip" == "$item" ]] && return 0
    done
    return 1
  fi

  python3 - "$client_ip" "${ip_list[@]}" >/dev/null 2>&1 <<'PY'
import sys
import ipaddress

client = ipaddress.ip_address(sys.argv[1])
networks = sys.argv[2:]

for net in networks:
    try:
        if client in ipaddress.ip_network(net, strict=False):
            sys.exit(0)
    except ValueError:
        pass

sys.exit(1)
PY
}

parse_ip_list() {
  local raw="$1"
  local item
  local -a items=()
  local -a result=()

  read -ra items <<< "${raw//,/ }"

  for item in "${items[@]}"; do
    [[ -z "$item" ]] && continue

    if is_valid_ip_or_cidr "$item"; then
      result+=("$item")
    else
      print_warn "Пропускаю некорректный IP/CIDR: $item"
    fi
  done

  if [[ "${#result[@]}" -eq 0 ]]; then
    print_err "Не указано ни одного корректного IP/CIDR."
    return 1
  fi

  printf '%s\n' "${result[@]}"
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# "443" -> "443", "6000-6010" / "6000:6010" -> "6000:6010"
normalize_port_spec() {
  local spec="${1//-/:}"
  local a
  local b

  if [[ "$spec" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))

    if validate_port "$a" && validate_port "$b" && (( a < b )); then
      echo "$a:$b"
      return 0
    fi
    return 1
  fi

  if validate_port "$spec"; then
    echo "$((10#$spec))"
    return 0
  fi

  return 1
}

validate_port_spec() {
  normalize_port_spec "$1" >/dev/null
}

port_spec_has_port() {
  local spec="$1"
  local port="$2"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  if [[ "$spec" == *:* ]]; then
    (( 10#$port >= 10#${spec%%:*} && 10#$port <= 10#${spec##*:} ))
  else
    (( 10#$spec == 10#$port ))
  fi
}

is_ssh_port_spec() {
  local spec="$1"
  local ssh_port

  ssh_port="$(get_ssh_server_port)"
  port_spec_has_port "$spec" "$ssh_port" || port_spec_has_port "$spec" 22
}

# Список портов ufw вида "80,443,6000:6010" покрывает порт (с учётом диапазонов)
port_list_covers() {
  local list="$1"
  local port="$2"
  local item
  local -a items=()

  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^[0-9]+(:[0-9]+)?$ ]] && port_spec_has_port "$item" "$port"; then
      return 0
    fi
  done
  return 1
}

# Список портов содержит ровно этот порт (без диапазонов)
port_list_has_exact() {
  local list="$1"
  local port="$2"
  local item
  local -a items=()

  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    [[ "$item" =~ ^[0-9]+$ ]] || continue
    if (( 10#$item == 10#$port )); then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Разбор правил ufw
# ---------------------------------------------------------------------------

# Строки "номер|правило" из ufw status numbered
get_numbered_rules() {
  ufw_c status numbered 2>/dev/null | sed -nE 's/^\[[[:space:]]*([0-9]+)\][[:space:]]*(.*)$/\1|\2/p' || true
}

get_max_rule_number() {
  get_numbered_rules | tail -n1 | cut -d'|' -f1 || true
}

# Разбивает строку правила на "to|action|from|comment"
split_rule_line() {
  awk '{
    line = $0
    if (!match(line, /[ \t]+(ALLOW|DENY|REJECT|LIMIT)( (IN|OUT|FWD))?[ \t]+/)) next
    to = substr(line, 1, RSTART - 1)
    action = substr(line, RSTART, RLENGTH)
    rest = substr(line, RSTART + RLENGTH)
    from = rest
    comment = ""
    i = index(rest, "#")
    if (i > 0) {
      from = substr(rest, 1, i - 1)
      comment = substr(rest, i + 1)
    }
    gsub(/^[ \t]+|[ \t]+$/, "", to)
    gsub(/^[ \t]+|[ \t]+$/, "", action)
    gsub(/^[ \t]+|[ \t]+$/, "", from)
    gsub(/^[ \t]+|[ \t]+$/, "", comment)
    print to "|" action "|" from "|" comment
  }' <<< "$1"
}

# Правило разрешает доступ к SSH (удаление может оборвать доступ)
rule_looks_like_ssh() {
  local line="$1"
  local ssh_port="$2"
  local to action from comment w port_list
  local found_port=0
  local -a words=()

  IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"

  if [[ -z "$to" ]]; then
    # Не удалось разобрать строку — перестраховываемся
    echo "$line" | grep -Eiq "ssh|(^|[^0-9])(22|${ssh_port})([^0-9]|$)"
    return
  fi

  case "$action" in
    ALLOW*|LIMIT*) ;;
    *) return 1 ;;
  esac

  if [[ "${to,,}" == *ssh* || "${comment,,}" == *ssh* ]]; then
    return 0
  fi

  to="${to% (v6)}"
  read -ra words <<< "$to"

  for w in "${words[@]}"; do
    if [[ "$w" =~ ^([0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*)(/(tcp|udp))?$ ]]; then
      # Сохраняем сразу: port_list_covers внутри тоже использует =~ и перезапишет BASH_REMATCH
      port_list="${BASH_REMATCH[1]}"
      found_port=1

      if port_list_covers "$port_list" "$ssh_port" || port_list_covers "$port_list" 22; then
        return 0
      fi
    fi
  done

  # Правило без порта (например, "Anywhere ALLOW IN 1.2.3.4") открывает все порты, включая SSH
  if (( found_port == 0 )); then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Включение ufw
# ---------------------------------------------------------------------------

ensure_ufw_enabled_safely() {
  local status
  local ssh_port
  local client_ip
  local answer

  status="$(get_ufw_status_word || true)"
  ssh_port="$(get_ssh_server_port)"
  client_ip="$(get_ssh_client_ip)"

  if [[ "$status" == "inactive" || -z "$status" ]]; then
    print_warn "ufw сейчас выключен."

    if [[ -n "$client_ip" ]]; then
      print_warn "Ты подключен по SSH с IP: $client_ip"
      print_warn "Текущий SSH-порт определён как: $ssh_port"
      echo >&2
      read -rp "Перед включением ufw разрешить SSH только с твоего текущего IP? [Y/n]: " answer || answer=""

      case "${answer,,}" in
        n|no|н|нет)
          print_warn "SSH не будет добавлен автоматически."
          ;;
        *)
          if is_ipv6_addr "$client_ip" && [[ "$(get_ipv6_state)" == "no" ]]; then
            print_info "Ты подключен по IPv6, а IPv6 в ufw выключен — ufw не фильтрует IPv6, SSH не пострадает."
          elif ufw allow from "$client_ip" to any port "$ssh_port" proto tcp comment "SAFE SSH from current IP"; then
            print_ok "Добавлено безопасное SSH-правило: $client_ip -> tcp/$ssh_port"
          else
            print_err "Не удалось добавить SSH-правило. Не включай ufw, пока не разберёшься."
          fi
          ;;
      esac
    else
      print_warn "Не удалось определить твой SSH IP."
      print_warn "Если ты на удалённом сервере, сначала убедись, что SSH-порт открыт."
      read -rp "Разрешить SSH tcp/$ssh_port для Anywhere перед включением ufw? [Y/n]: " answer || answer=""

      case "${answer,,}" in
        n|no|н|нет)
          ;;
        *)
          if ufw allow "$ssh_port/tcp" comment "SAFE SSH Anywhere"; then
            print_ok "Добавлено SSH-правило: Anywhere -> tcp/$ssh_port"
          else
            print_err "Не удалось добавить SSH-правило. Не включай ufw, пока не разберёшься."
          fi
          ;;
      esac
    fi

    echo >&2
    print_info "Рекомендуемая базовая политика: deny incoming, allow outgoing."
    read -rp "Применить базовую политику и включить ufw? [Y/n]: " answer || answer=""

    case "${answer,,}" in
      n|no|н|нет)
        print_warn "ufw оставлен выключенным. Правила можно добавлять, но они не будут активны до включения ufw."
        ;;
      *)
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
        print_ok "ufw включен."
        ;;
    esac
  else
    print_ok "ufw уже активен."
  fi
}

show_rules() {
  echo >&2
  print_info "Текущие правила ufw (IPv6: $(ipv6_state_label "$(get_ipv6_state)")):"
  echo >&2
  ufw status numbered verbose
}

# ---------------------------------------------------------------------------
# Вопросы пользователю
# ---------------------------------------------------------------------------

ask_protocol() {
  local default_proto="${1:-tcp}"
  local choice

  echo >&2
  echo "Выбери протокол:" >&2
  echo "1) TCP" >&2
  echo "2) UDP" >&2
  echo "3) TCP + UDP" >&2
  read -rp "Выбор [по умолчанию: $default_proto]: " choice || choice=""

  case "$choice" in
    1) echo "tcp" ;;
    2) echo "udp" ;;
    3) echo "both" ;;
    "")
      echo "$default_proto"
      ;;
    *)
      print_warn "Некорректный выбор. Использую $default_proto."
      echo "$default_proto"
      ;;
  esac
}

ask_scope() {
  local choice

  echo >&2
  echo "Выбери доступ:" >&2
  echo "1) Anywhere" >&2
  echo "2) Только конкретные IP/CIDR" >&2
  read -rp "Выбор [1]: " choice || choice=""

  case "$choice" in
    2) echo "acl" ;;
    *) echo "anywhere" ;;
  esac
}

ask_ip_list() {
  local raw
  local parsed

  echo >&2
  echo "Можно указать один IP, несколько IP через запятую или пробел, либо CIDR." >&2
  echo "Пример:" >&2
  echo "  1.2.3.4" >&2
  echo "  1.2.3.4, 5.6.7.8" >&2
  echo "  192.168.1.0/24 10.10.10.10" >&2
  echo >&2
  read -rp "IP/CIDR: " raw || raw=""

  parsed="$(parse_ip_list "$raw")" || return 1
  echo "$parsed"
}

ask_custom_port() {
  local port

  echo >&2
  read -rp "Введи порт от 1 до 65535: " port || port=""

  if ! validate_port "$port"; then
    print_err "Некорректный порт: $port"
    return 1
  fi

  echo "$((10#$port))"
}

# Возвращает: 0 — можно продолжать, 2 — в stdout IP, который нужно добавить, иное — отмена
confirm_ssh_acl_safety() {
  local port="$1"
  shift
  local ip_list=("$@")
  local client_ip
  local answer
  local confirm

  client_ip="$(get_ssh_client_ip)"

  if ! is_ssh_port_spec "$port"; then
    return 0
  fi

  if [[ -z "$client_ip" ]]; then
    print_warn "Не удалось определить твой текущий SSH IP."
    print_warn "Если добавить ACL без твоего IP, можно потерять SSH-доступ."
    read -rp "Продолжить? Напиши YES: " confirm || confirm=""
    [[ "$confirm" == "YES" ]]
    return
  fi

  if ip_in_list "$client_ip" "${ip_list[@]}"; then
    return 0
  fi

  echo >&2
  print_warn "ВНИМАНИЕ: ты подключен по SSH с IP: $client_ip"
  print_warn "Но этот IP не входит в список ACL."
  print_warn "Если удалить Anywhere или закрыть SSH, можно потерять доступ."

  read -rp "Добавить текущий IP $client_ip в ACL автоматически? [Y/n]: " answer || answer=""

  case "${answer,,}" in
    n|no|н|нет)
      read -rp "Продолжить без текущего IP? Напиши YES: " confirm || confirm=""
      [[ "$confirm" == "YES" ]]
      ;;
    *)
      echo "$client_ip"
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Добавление правил
# ---------------------------------------------------------------------------

apply_allow_rule() {
  local port="$1"
  local proto="$2"
  local scope="$3"
  local comment="${4:-SMART UFW}"
  shift 4
  local ip_list=("$@")
  local p
  local ip
  local failed=0

  if ! validate_port_spec "$port"; then
    print_err "Некорректный порт или диапазон: $port"
    return 1
  fi

  if [[ "$proto" == "both" ]]; then
    for p in tcp udp; do
      apply_allow_rule "$port" "$p" "$scope" "$comment" "${ip_list[@]}" || failed=1
    done
    return "$failed"
  fi

  if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
    print_err "Некорректный протокол: $proto"
    return 1
  fi

  if [[ "$scope" == "anywhere" ]]; then
    if ufw allow "$port/$proto" comment "$comment"; then
      print_ok "Открыто: Anywhere -> $proto/$port"
    else
      print_err "Не удалось открыть: Anywhere -> $proto/$port"
      failed=1
    fi
  elif [[ "$scope" == "acl" ]]; then
    if [[ "${#ip_list[@]}" -eq 0 ]]; then
      print_err "Для ACL не передан список IP."
      return 1
    fi

    for ip in "${ip_list[@]}"; do
      if is_ipv6_addr "$ip" && [[ "$(get_ipv6_state)" == "no" ]]; then
        print_warn "Пропускаю $ip: IPv6 в ufw выключен (пункт 13 меню)."
        failed=1
        continue
      fi

      if ufw allow from "$ip" to any port "$port" proto "$proto" comment "$comment"; then
        print_ok "Открыто: $ip -> $proto/$port"
      else
        print_err "Не удалось открыть: $ip -> $proto/$port"
        failed=1
      fi
    done
  else
    print_err "Некорректный scope: $scope"
    return 1
  fi

  return "$failed"
}

open_port_interactive() {
  local service_name="$1"
  local port="$2"
  local forced_proto="${3:-}"
  local proto
  local scope
  local ip_lines
  local ip_list=()
  local extra_ip=""
  local rc

  echo >&2
  print_info "Настройка правила: $service_name, порт $port"

  if [[ "$forced_proto" == "both" ]]; then
    proto="both"
    print_info "Для этого пункта будет открыт TCP + UDP."
  elif [[ "$forced_proto" == "tcp" || "$forced_proto" == "udp" ]]; then
    proto="$forced_proto"
    print_info "Для этого пункта будет открыт протокол: $proto"
  else
    proto="$(ask_protocol "tcp")"
  fi

  scope="$(ask_scope)"

  if [[ "$scope" == "acl" ]]; then
    ip_lines="$(ask_ip_list)" || return 0
    mapfile -t ip_list <<< "$ip_lines"

    if [[ "$service_name" == "SSH" ]] || is_ssh_port_spec "$port"; then
      set +e
      extra_ip="$(confirm_ssh_acl_safety "$port" "${ip_list[@]}")"
      rc=$?
      set -e

      if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
        ip_list+=("$extra_ip")
        print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
      elif [[ "$rc" -ne 0 ]]; then
        print_err "Операция отменена для защиты SSH-доступа."
        return 0
      fi
    fi
  fi

  apply_allow_rule "$port" "$proto" "$scope" "SMART UFW: $service_name" "${ip_list[@]}" \
    || print_warn "Не все правила применены, проверь вывод выше."
  reload_ufw
}

open_custom_port() {
  local port

  port="$(ask_custom_port)" || return 0
  open_port_interactive "Custom port $port" "$port"
}

# Разбирает "80 443/udp 500/both 6000:6010" в строки "spec|proto" (proto может быть пустым)
parse_port_entries() {
  local raw="${1,,}"
  local item spec proto norm
  local count=0
  local -a items=()

  read -ra items <<< "${raw//,/ }"

  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([0-9:-]+)(/(tcp|udp|both|any))?$ ]]; then
      spec="${BASH_REMATCH[1]}"
      proto="${BASH_REMATCH[3]:-}"

      if [[ "$proto" == "any" ]]; then
        proto="both"
      fi

      if norm="$(normalize_port_spec "$spec")"; then
        echo "$norm|$proto"
        count=$((count + 1))
      else
        print_warn "Некорректный порт или диапазон, пропускаю: $item"
      fi
    else
      print_warn "Не понял запись, пропускаю: $item"
    fi
  done

  if (( count == 0 )); then
    print_err "Не указано ни одного корректного порта."
    return 1
  fi

  return 0
}

bulk_add_ports() {
  local raw parsed entry spec proto scope ip_lines extra_ip rc src
  local default_proto="tcp"
  local needs_proto=0
  local has_ssh=0
  local failed=0
  local -a entries=()
  local -a ip_list=()

  echo >&2
  echo "Укажи порты через пробел или запятую. Можно сразу задать протокол и диапазоны:" >&2
  echo "  80 443 8443" >&2
  echo "  53/udp 500/both 51820/udp" >&2
  echo "  6000:6010/tcp 7000-7005" >&2
  echo >&2
  read -rp "Порты: " raw || return 0

  parsed="$(parse_port_entries "$raw")" || return 0
  mapfile -t entries <<< "$parsed"

  for entry in "${entries[@]}"; do
    if [[ -z "${entry#*|}" ]]; then
      needs_proto=1
    fi
    if is_ssh_port_spec "${entry%%|*}"; then
      has_ssh=1
    fi
  done

  if (( needs_proto )); then
    echo >&2
    echo "Протокол для портов, где он не указан явно:" >&2
    default_proto="$(ask_protocol "tcp")"
  fi

  scope="$(ask_scope)"

  if [[ "$scope" == "acl" ]]; then
    ip_lines="$(ask_ip_list)" || return 0
    mapfile -t ip_list <<< "$ip_lines"

    if (( has_ssh )); then
      set +e
      extra_ip="$(confirm_ssh_acl_safety "$(get_ssh_server_port)" "${ip_list[@]}")"
      rc=$?
      set -e

      if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
        ip_list+=("$extra_ip")
        print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
      elif [[ "$rc" -ne 0 ]]; then
        print_err "Операция отменена для защиты SSH-доступа."
        return 0
      fi
    fi

    src="$(IFS=','; echo "${ip_list[*]}")"
  else
    src="Anywhere"
  fi

  echo >&2
  print_info "Будут добавлены правила:"
  for entry in "${entries[@]}"; do
    spec="${entry%%|*}"
    proto="${entry#*|}"
    proto="${proto:-$default_proto}"
    printf '  %-14s %-5s <- %s\n' "$spec" "$proto" "$src" >&2
  done
  echo >&2

  if ! confirm_yes_no "Применить? [y/N]: " n; then
    print_warn "Отменено."
    return 0
  fi

  for entry in "${entries[@]}"; do
    spec="${entry%%|*}"
    proto="${entry#*|}"
    proto="${proto:-$default_proto}"
    apply_allow_rule "$spec" "$proto" "$scope" "SMART UFW: bulk $spec" "${ip_list[@]}" \
      || failed=$((failed + 1))
  done

  if (( failed > 0 )); then
    print_warn "Не все правила применены, проверь вывод выше."
  fi

  reload_ufw
}

bulk_add_from_lines() {
  local path line spec_raw spec proto src item shown rc extra_ip ssh_port i
  local f_port f_src f_comment
  local lineno=0
  local errors=0
  local failed=0
  local active=0
  local -a raw_lines=()
  local -a parts=()
  local -a ips=()
  local -a e_spec=()
  local -a e_proto=()
  local -a e_src=()
  local -a e_comment=()

  echo >&2
  echo "Формат строки:  ПОРТ[/ПРОТОКОЛ]  [ИСТОЧНИК]  [КОММЕНТАРИЙ]" >&2
  echo "  ПРОТОКОЛ — tcp | udp | both (по умолчанию tcp)" >&2
  echo "  ИСТОЧНИК — any (по умолчанию) или IP/CIDR через запятую без пробелов" >&2
  echo "  Пустые строки и строки, начинающиеся с #, пропускаются." >&2
  echo "Пример:" >&2
  echo "  443/tcp" >&2
  echo "  500/both       any                  ipsec" >&2
  echo "  8443/tcp       1.2.3.4,10.0.0.0/8   admin panel" >&2
  echo "  6000:6010/udp  5.6.7.8" >&2
  echo >&2
  read -rp "Путь к файлу с правилами (Enter — ввести вручную): " path || return 0
  path="$(trim "$path")"

  if [[ -n "$path" ]]; then
    if [[ ! -r "$path" ]]; then
      print_err "Файл не найден или недоступен: $path"
      return 0
    fi
    mapfile -t raw_lines < "$path"
  else
    echo "Вводи правила по одному в строке. Пустая строка — конец ввода." >&2
    while IFS= read -rp "> " line; do
      if [[ -z "$(trim "$line")" ]]; then
        break
      fi
      raw_lines+=("$line")
    done
  fi

  for line in "${raw_lines[@]}"; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="$(trim "$line")"

    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    f_port=""
    f_src=""
    f_comment=""
    read -r f_port f_src f_comment <<< "$line"

    if [[ "$f_src" == \#* ]]; then
      f_comment="$f_src $f_comment"
      f_src=""
    fi

    f_port="${f_port,,}"
    if [[ ! "$f_port" =~ ^([0-9:-]+)(/(tcp|udp|both|any))?$ ]]; then
      print_warn "Строка $lineno: не понял порт '$f_port' — пропускаю."
      errors=$((errors + 1))
      continue
    fi

    spec_raw="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[3]:-tcp}"
    if [[ "$proto" == "any" ]]; then
      proto="both"
    fi

    if ! spec="$(normalize_port_spec "$spec_raw")"; then
      print_warn "Строка $lineno: некорректный порт или диапазон '$spec_raw' — пропускаю."
      errors=$((errors + 1))
      continue
    fi

    case "${f_src,,}" in
      ""|any|anywhere|"*"|-)
        src="any"
        ;;
      *)
        src=""
        IFS=',' read -ra parts <<< "$f_src"
        for item in "${parts[@]}"; do
          [[ -z "$item" ]] && continue
          if ! is_valid_ip_or_cidr "$item"; then
            print_warn "Строка $lineno: некорректный IP/CIDR '$item' — строка пропущена."
            src="!"
            break
          fi
          src="${src:+$src,}$item"
        done

        if [[ "$src" == "!" || -z "$src" ]]; then
          errors=$((errors + 1))
          continue
        fi
        ;;
    esac

    f_comment="${f_comment#\#}"
    f_comment="$(trim "$f_comment")"
    f_comment="${f_comment//[\'\"]/}"

    e_spec+=("$spec")
    e_proto+=("$proto")
    e_src+=("$src")
    e_comment+=("$f_comment")
  done

  if (( ${#e_spec[@]} == 0 )); then
    print_err "Нет ни одного корректного правила."
    return 0
  fi

  if (( errors > 0 )); then
    print_warn "Строк с ошибками: $errors."
    if ! confirm_yes_no "Продолжить только с корректными строками? [y/N]: " n; then
      print_warn "Отменено."
      return 0
    fi
  fi

  ssh_port="$(get_ssh_server_port)"
  for i in "${!e_spec[@]}"; do
    [[ "${e_src[$i]}" == "any" ]] && continue
    is_ssh_port_spec "${e_spec[$i]}" || continue

    IFS=',' read -ra ips <<< "${e_src[$i]}"
    print_info "Проверка SSH для правила: ${e_spec[$i]} <- ${e_src[$i]}"

    set +e
    extra_ip="$(confirm_ssh_acl_safety "$ssh_port" "${ips[@]}")"
    rc=$?
    set -e

    if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
      e_src[$i]="${e_src[$i]},$extra_ip"
      print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
    elif [[ "$rc" -ne 0 ]]; then
      print_warn "Правило ${e_spec[$i]} исключено для защиты SSH-доступа."
      e_src[$i]="skip"
    fi
  done

  echo >&2
  print_info "Будут добавлены правила:"
  for i in "${!e_spec[@]}"; do
    [[ "${e_src[$i]}" == "skip" ]] && continue
    active=$((active + 1))
    shown="${e_src[$i]}"
    if [[ "$shown" == "any" ]]; then
      shown="Anywhere"
    fi
    printf '  %-14s %-5s <- %-32s %s\n' "${e_spec[$i]}" "${e_proto[$i]}" "$shown" "${e_comment[$i]}" >&2
  done
  echo >&2

  if (( active == 0 )); then
    print_warn "Применять нечего."
    return 0
  fi

  if ! confirm_yes_no "Применить $active правил(а)? [y/N]: " n; then
    print_warn "Отменено."
    return 0
  fi

  for i in "${!e_spec[@]}"; do
    [[ "${e_src[$i]}" == "skip" ]] && continue

    if [[ "${e_src[$i]}" == "any" ]]; then
      apply_allow_rule "${e_spec[$i]}" "${e_proto[$i]}" "anywhere" \
        "SMART UFW: ${e_comment[$i]:-bulk}" || failed=$((failed + 1))
    else
      IFS=',' read -ra ips <<< "${e_src[$i]}"
      apply_allow_rule "${e_spec[$i]}" "${e_proto[$i]}" "acl" \
        "SMART UFW: ${e_comment[$i]:-bulk}" "${ips[@]}" || failed=$((failed + 1))
    fi
  done

  if (( failed > 0 )); then
    print_warn "Не все правила применены, проверь вывод выше."
  fi

  reload_ufw
}

bulk_add_rules() {
  local choice

  echo >&2
  echo "Массовое добавление правил:" >&2
  echo "1) Список портов с одинаковым доступом" >&2
  echo "2) Пакетный ввод: каждая строка — отдельное правило (файл или вручную)" >&2
  echo "0) Назад" >&2
  read -rp "Выбор: " choice || return 0

  case "$choice" in
    1) bulk_add_ports ;;
    2) bulk_add_from_lines ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Удаление правил
# ---------------------------------------------------------------------------

# Показывает выбранные правила, спрашивает подтверждение и удаляет их от большего номера к меньшему
confirm_and_delete_numbers() {
  local n line ssh_port confirm mark i
  local has_ssh=0
  local deleted=0
  local failed=0
  local -a nums=()
  local -A rule_map=()

  if (( $# == 0 )); then
    print_warn "Нечего удалять."
    return 0
  fi

  mapfile -t nums < <(printf '%s\n' "$@" | sort -rnu)
  ssh_port="$(get_ssh_server_port)"

  while IFS='|' read -r n line; do
    [[ -n "$n" ]] && rule_map["$n"]="$line"
  done < <(get_numbered_rules)

  echo >&2
  print_info "Выбрано правил: ${#nums[@]}"

  for (( i=${#nums[@]}-1 ; i>=0 ; i-- )); do
    n="${nums[$i]}"
    line="${rule_map[$n]:-}"

    if [[ -z "$line" ]]; then
      print_err "Правило [$n] не найдено. Операция отменена."
      return 0
    fi

    mark=""
    if rule_looks_like_ssh "$line" "$ssh_port"; then
      mark="  ${YELLOW}<- SSH${NC}"
      has_ssh=1
    fi
    echo -e "  [$n] $line$mark" >&2
  done
  echo >&2

  if (( has_ssh )); then
    print_warn "Среди выбранных есть правила, похожие на SSH-доступ."
    print_warn "Удаление может оборвать доступ к серверу."
    read -rp "Для подтверждения напиши DELETE-SSH: " confirm || confirm=""

    if [[ "$confirm" != "DELETE-SSH" ]]; then
      print_err "Удаление отменено."
      return 0
    fi
  else
    if ! confirm_yes_no "Удалить выбранные правила? [y/N]: " n; then
      print_warn "Удаление отменено."
      return 0
    fi
  fi

  for n in "${nums[@]}"; do
    if ufw --force delete "$n" >/dev/null; then
      deleted=$((deleted + 1))
    else
      print_err "Не удалось удалить правило [$n]"
      failed=$((failed + 1))
    fi
  done

  print_ok "Удалено правил: $deleted"
  if (( failed > 0 )); then
    print_warn "Ошибок при удалении: $failed"
  fi

  reload_ufw
}

delete_rule_by_number() {
  local num
  local max

  show_rules

  max="$(get_max_rule_number)"
  if [[ -z "$max" ]]; then
    print_info "Правил нет (или ufw выключен — в этом состоянии ufw status не показывает правила)."
    return 0
  fi

  echo >&2
  read -rp "Введи номер правила для удаления: " num || return 0

  if ! [[ "$num" =~ ^[0-9]{1,6}$ ]] || (( 10#$num < 1 || 10#$num > max )); then
    print_err "Правило с номером $num не найдено."
    return 0
  fi

  confirm_and_delete_numbers "$((10#$num))"
}

# "1 3 5-8, 10" / "all" -> уникальные номера по убыванию
parse_number_list() {
  local raw="$1"
  local max="$2"
  local item a b n
  local -a items=()
  local -a nums=()

  read -ra items <<< "${raw//,/ }"

  for item in "${items[@]}"; do
    if [[ "${item,,}" == "all" ]]; then
      for (( n=1 ; n<=max ; n++ )); do
        nums+=("$n")
      done
    elif [[ "$item" =~ ^([0-9]{1,6})-([0-9]{1,6})$ ]]; then
      a=$((10#${BASH_REMATCH[1]}))
      b=$((10#${BASH_REMATCH[2]}))

      if (( a > b )); then
        n=$a; a=$b; b=$n
      fi
      if (( b > max )); then
        print_warn "Диапазон $item выходит за пределы (всего правил: $max), обрезаю."
        b=$max
      fi
      if (( a < 1 )); then
        a=1
      fi

      for (( n=a ; n<=b ; n++ )); do
        nums+=("$n")
      done
    elif [[ "$item" =~ ^[0-9]{1,6}$ ]]; then
      n=$((10#$item))
      if (( n >= 1 && n <= max )); then
        nums+=("$n")
      else
        print_warn "Правила [$n] нет, пропускаю."
      fi
    else
      print_warn "Не понял запись, пропускаю: $item"
    fi
  done

  if (( ${#nums[@]} > 0 )); then
    printf '%s\n' "${nums[@]}" | sort -rnu
  fi

  return 0
}

collect_rules_by_port() {
  local port="$1"
  local proto="$2"
  local n line to action from comment w w_proto w_list
  local -a words=()

  while IFS='|' read -r n line; do
    IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"
    to="${to% (v6)}"
    read -ra words <<< "$to"

    for w in "${words[@]}"; do
      [[ "$w" =~ ^([0-9,:]+)(/(tcp|udp))?$ ]] || continue
      # Сохраняем сразу, до вызова других функций с =~
      w_list="${BASH_REMATCH[1]}"
      w_proto="${BASH_REMATCH[3]:-}"

      if [[ "$proto" != "any" && -n "$w_proto" && "$w_proto" != "$proto" ]]; then
        continue
      fi

      if port_list_has_exact "$w_list" "$port"; then
        echo "$n"
        break
      fi
    done
  done < <(get_numbered_rules)
}

collect_rules_by_comment() {
  local pattern="${1,,}"
  local n line to action from comment

  while IFS='|' read -r n line; do
    IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"
    if [[ -n "$comment" && "${comment,,}" == *"$pattern"* ]]; then
      echo "$n"
    fi
  done < <(get_numbered_rules)
}

collect_rules_by_source() {
  local source="$1"
  local n line to action from comment

  while IFS='|' read -r n line; do
    IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"
    from="${from% (v6)}"
    if [[ "$from" == "$source" ]]; then
      echo "$n"
    fi
  done < <(get_numbered_rules)
}

bulk_delete_rules() {
  local choice raw max port proto pattern source
  local -a nums=()

  show_rules

  max="$(get_max_rule_number)"
  if [[ -z "$max" ]]; then
    print_info "Правил нет (или ufw выключен — в этом состоянии ufw status не показывает правила)."
    return 0
  fi

  echo >&2
  echo "Массовое удаление правил:" >&2
  echo "1) По номерам и диапазонам (например: 3 5 7-10, или all)" >&2
  echo "2) Все правила для порта" >&2
  echo "3) Все правила по тексту комментария (по умолчанию: SMART UFW)" >&2
  echo "4) Все правила для IP/CIDR источника" >&2
  echo "0) Назад" >&2
  read -rp "Выбор: " choice || return 0

  case "$choice" in
    1)
      read -rp "Номера правил: " raw || return 0
      mapfile -t nums < <(parse_number_list "$raw" "$max")
      ;;
    2)
      read -rp "Порт: " port || return 0
      if ! validate_port "$port"; then
        print_err "Некорректный порт: $port"
        return 0
      fi

      echo >&2
      echo "Какие протоколы удалять:" >&2
      echo "1) Любые" >&2
      echo "2) Только TCP" >&2
      echo "3) Только UDP" >&2
      read -rp "Выбор [1]: " proto || proto=""

      case "$proto" in
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="any" ;;
      esac

      mapfile -t nums < <(collect_rules_by_port "$((10#$port))" "$proto")
      ;;
    3)
      read -rp "Текст в комментарии [SMART UFW]: " pattern || pattern=""
      pattern="$(trim "$pattern")"
      pattern="${pattern:-SMART UFW}"
      mapfile -t nums < <(collect_rules_by_comment "$pattern")
      ;;
    4)
      read -rp "IP/CIDR источника (как в колонке From): " source || return 0
      source="$(trim "$source")"
      if ! is_valid_ip_or_cidr "$source"; then
        print_err "Некорректный IP/CIDR: $source"
        return 0
      fi
      mapfile -t nums < <(collect_rules_by_source "$source")
      ;;
    *)
      return 0
      ;;
  esac

  if (( ${#nums[@]} == 0 )); then
    print_warn "Подходящих правил не найдено."
    return 0
  fi

  confirm_and_delete_numbers "${nums[@]}"
}

delete_anywhere_rules_for_port_proto() {
  local port="$1"
  local proto="$2"
  local n line to action from comment idx
  local found_generic=0
  local -a numbers=()

  while IFS='|' read -r n line; do
    IFS='|' read -r to action from comment <<< "$(split_rule_line "$line")"

    case "$action" in
      ALLOW*) ;;
      *) continue ;;
    esac

    to="${to% (v6)}"
    from="${from% (v6)}"
    [[ "$from" == "Anywhere" ]] || continue

    if [[ "$to" == "$port/$proto" ]]; then
      numbers+=("$n")
    elif [[ "$to" == "$port" ]]; then
      found_generic=1
    fi
  done < <(get_numbered_rules)

  if (( found_generic )); then
    print_warn "Есть Anywhere-правило '$port' без протокола (TCP+UDP сразу)."
    print_warn "Его скрипт не трогает — при необходимости удали вручную (пункт 8 или 12)."
  fi

  if [[ "${#numbers[@]}" -eq 0 ]]; then
    print_info "Anywhere-правил для $proto/$port не найдено."
    return 0
  fi

  print_warn "Будут удалены Anywhere-правила для $proto/$port: ${numbers[*]}"
  if ! confirm_yes_no "Удалить эти Anywhere-правила? [y/N]: " n; then
    print_warn "Удаление Anywhere-правил отменено."
    return 0
  fi

  for (( idx=${#numbers[@]}-1 ; idx>=0 ; idx-- )); do
    ufw --force delete "${numbers[$idx]}" >/dev/null || print_err "Не удалось удалить правило [${numbers[$idx]}]"
  done

  print_ok "Anywhere-правила удалены."
}

restrict_existing_port_with_acl() {
  local port
  local proto
  local ip_lines
  local ip_list=()
  local extra_ip=""
  local rc

  show_rules

  echo >&2
  read -rp "Введи порт, к которому нужно добавить ACL: " port || return 0

  if ! validate_port "$port"; then
    print_err "Некорректный порт."
    return 0
  fi
  port="$((10#$port))"

  proto="$(ask_protocol "tcp")"

  ip_lines="$(ask_ip_list)" || return 0
  mapfile -t ip_list <<< "$ip_lines"

  if is_ssh_port_spec "$port"; then
    set +e
    extra_ip="$(confirm_ssh_acl_safety "$port" "${ip_list[@]}")"
    rc=$?
    set -e

    if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
      ip_list+=("$extra_ip")
      print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
    elif [[ "$rc" -ne 0 ]]; then
      print_err "Операция отменена для защиты SSH-доступа."
      return 0
    fi
  fi

  if ! apply_allow_rule "$port" "$proto" "acl" "SMART UFW ACL for port $port" "${ip_list[@]}"; then
    print_warn "Часть ACL-правил не применена."
    print_warn "Удаление Anywhere-правил пропущено, чтобы не закрыть порт целиком."
    reload_ufw
    return 0
  fi

  echo >&2
  print_warn "ACL добавлен. Но если раньше был открыт Anywhere, он останется, пока его не удалить."

  if confirm_yes_no "Удалить Anywhere-правила для этого порта/протокола? [y/N]: " n; then
    if [[ "$proto" == "both" ]]; then
      delete_anywhere_rules_for_port_proto "$port" "tcp"
      delete_anywhere_rules_for_port_proto "$port" "udp"
    else
      delete_anywhere_rules_for_port_proto "$port" "$proto"
    fi
  else
    print_warn "Anywhere-правила не удалялись."
  fi

  reload_ufw
}

reload_ufw() {
  local status

  echo >&2
  status="$(get_ufw_status_word || true)"

  if [[ "$status" != "active" ]]; then
    print_warn "ufw выключен — правила сохранены, но не будут активны, пока ufw не включён."
    return 0
  fi

  print_info "Перезагружаю правила ufw..."

  if ufw reload; then
    print_ok "Правила ufw загружены."
    return 0
  fi

  print_warn "ufw reload не сработал. Пробую ufw --force enable..."
  if ufw --force enable; then
    print_ok "ufw включен и правила загружены."
  else
    print_err "Не удалось включить ufw. Проверь вручную: ufw status verbose"
  fi
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------

main_menu() {
  local ssh_port
  local choice

  while true; do
    ssh_port="$(get_ssh_server_port)"

    clear || true
    echo "============================================"
    echo " SMART UFW MANAGER"
    echo "============================================"
    echo
    echo "Текущий SSH-порт определен как: $ssh_port"
    echo "IPv6 в ufw: $(ipv6_state_label "$(get_ipv6_state)")"
    echo
    echo "Основные действия:"
    echo "1) Открыть SSH"
    echo "2) Открыть 443"
    echo "3) Открыть 80"
    echo "4) Открыть 2053"
    echo "5) Открыть 500 TCP + UDP"
    echo "6) Открыть свой порт"
    echo
    echo "Управление правилами:"
    echo "7) Показать текущие правила"
    echo "8) Удалить правило по номеру"
    echo "9) Добавить ACL к существующему порту"
    echo "10) Перезагрузить ufw rules"
    echo
    echo "Массовые операции и настройки:"
    echo "11) Массовое добавление правил"
    echo "12) Массовое удаление правил"
    echo "13) Включить/выключить IPv6"
    echo
    echo "0) Выход"
    echo
    read -rp "Выбор: " choice || exit 0

    case "$choice" in
      1)
        open_port_interactive "SSH" "$ssh_port" "tcp"
        pause
        ;;
      2)
        open_port_interactive "HTTPS 443" "443"
        pause
        ;;
      3)
        open_port_interactive "HTTP 80" "80"
        pause
        ;;
      4)
        open_port_interactive "Port 2053" "2053"
        pause
        ;;
      5)
        open_port_interactive "Port 500" "500" "both"
        pause
        ;;
      6)
        open_custom_port
        pause
        ;;
      7)
        show_rules
        pause
        ;;
      8)
        delete_rule_by_number
        pause
        ;;
      9)
        restrict_existing_port_with_acl
        pause
        ;;
      10)
        ensure_ufw_enabled_safely
        reload_ufw
        show_rules
        pause
        ;;
      11)
        bulk_add_rules
        pause
        ;;
      12)
        bulk_delete_rules
        pause
        ;;
      13)
        manage_ipv6
        pause
        ;;
      0)
        reload_ufw
        echo
        print_ok "Готово."
        exit 0
        ;;
      *)
        print_warn "Некорректный выбор."
        pause
        ;;
    esac
  done
}

main() {
  run_as_root "$@"
  SSH_CONN="$(find_ssh_connection || true)"
  check_ufw_installed
  ensure_ufw_enabled_safely
  main_menu
}

main "$@"