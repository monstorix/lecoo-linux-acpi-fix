# ACPI-патчи для Lecoo Pro 14 (N155A) — BIOS 2.5

[English](README.md) | [中文](README_ZH.md) | Русский

Дамп и набор патчей для **Lecoo Pro 14 (N155A)** с **BIOS 2.5**
(DSDT OEM revision `0x01072009`).

В этой прошивке остаются две проблемы:

- **Выключение иногда заканчивается перезагрузкой.** Если перед выключением отвязать
  драйвер проводной сети, этого не происходит.
- **s2idle возобновляется примерно через 0,5 с.** Вывод `0x0018` объявлен в таблицах
  ACPI источником пробуждения и активируется сетевой картой во время сна. Изменить это
  можно только в таблице.

Патч также содержит две службы systemd: одна отключает включающиеся снова после каждой
загрузки источники пробуждения, вторая отвязывает драйвер сети при выключении. Исправления
не зависят друг от друга; для обеих проблем нужно установить все три части.

Заметки к патчу (`CHANGES.md`) и справочник по симптомам (`SYMPTOMS.md`) — в
`patches/bios-0x01072009/`.

## Перед началом

### BIOS

- **ACPI = Auto** (Advanced → ACPI Settings). Если указано Disabled, своя таблица не
  загружается.
- **Сначала настройте подпись Secure Boot.** Подпишите цепочку загрузки с помощью sbctl
  или средства из дистрибутива, затем загружайте патч через хук из шага 2a — таблицы
  находятся внутри initramfs или UKI и подписываются вместе с ним. Для отдельного cpio из
  шага 2b подпишите файл или добавьте контрольную сумму так, как требует загрузчик.
- **Оставьте fTPM включённым.** Таблица генерируется локально, и перед снятием дампа
  скрипт проверяет, что ни одно переопределение не загружено; полученная таблица на fTPM
  не влияет.
- Если таблица не даёт эффекта, отключите **Fast Boot**: некоторые прошивки сохраняют
  собственную копию таблиц.

### Какие файлы относятся к вашей системе

Шаги ниже охватывают загрузчики Limine, GRUB, systemd-boot и генераторы initramfs
mkinitcpio и dracut. Следующие команды показывают, какая комбинация используется:

```
test -f /etc/mkinitcpio.conf && echo mkinitcpio
test -f /etc/dracut.conf && echo dracut
ls /boot/loader/entries/*.conf 2>/dev/null && echo systemd-boot
test -f /etc/default/grub && echo grub
test -f /etc/default/limine && echo limine
ls /boot/EFI/Linux/*.efi 2>/dev/null && echo "UKI (unified kernel image)"
```

Если в `/boot/EFI/Linux/` есть файлы `.efi`, ядро и initramfs упакованы в один
подписанный образ (UKI). В этом случае таблицы должны находиться внутри этого образа,
а настройки initramfs в конфигурации загрузчика не используются.

## Шаг 1 — параметры ядра

Добавьте в командную строку ядра параметры, перечисленные ниже. В конфигурации, с которой
получены эти заметки, они используются вместе:

| Параметр | Действие |
|---|---|
| `acpi.ec_no_wakeup=1` | убирает GPE контроллера EC из источников пробуждения; влияет на самопроизвольное включение после выключения |
| `acpi_osi="!Windows 2020"` | прошивка больше не сообщает о поддержке Windows 2020 и остаётся на более ранней ветке питания и ожидания (Windows 10) |
| `acpi=force` | оставляет ACPI включённым, даже если прошивка о нём не сообщает; на большинстве систем UEFI видимых изменений нет |
| `i8042.nomux` | пропускает определение мультиплексора портов PS/2 |

Все четыре рекомендуется сохранить, чтобы поведение питания соответствовало описанной
здесь конфигурации.

| Загрузчик | Файл и запись | Применение |
|---|---|---|
| Limine | `/etc/default/limine`, `KERNEL_CMDLINE[default]+="..."` | `sudo limine-update` |
| GRUB (Debian, Ubuntu) | `/etc/default/grub`, `GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo update-grub` |
| GRUB (Arch) | `/etc/default/grub`, `GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` |
| GRUB (Fedora) | `/etc/default/grub`, `GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` |
| systemd-boot | `/boot/loader/entries/*.conf`, строка `options ...` | записи читаются напрямую |
| systemd-boot, записи создаёт `kernel-install` | `/etc/kernel/cmdline` | после правки переустановите текущее ядро или дождитесь следующего обновления ядра |

`/boot/limine.conf` создаётся командой `limine-update`; изменять следует
`/etc/default/limine`, иначе правка будет перезаписана при обновлении ядра.

После перезагрузки `cat /proc/cmdline` должен содержать `acpi.ec_no_wakeup=1`.

## Шаг 2 — сборка переопределяющей таблицы

Соберите переопределяющую таблицу на целевой машине; переопределяется только
`ssdt-cpmgpio0`. Команда зависит от генератора initramfs:

| Генератор initramfs | Команда | Загрузка |
|---|---|---|
| mkinitcpio (Arch, CachyOS, ...) | `sudo ./rebuild_patch.sh --minimal --install-acpi --no-cpio` | шаг 2a |
| dracut и другие | `sudo ./rebuild_patch.sh --minimal` | шаг 2b |

Скрипт читает таблицы из работающей прошивки, заменяет `ExclusiveAndWake` на
`Exclusive` для вывода `0x0018` в `_AEI` и копирует результат компиляции в
`/etc/initcpio/acpi_override/`. Он также проверяет, не загружено ли сейчас
переопределение: иначе в дамп попадёт изменённая таблица вместо заводской.

Путь mkinitcpio не собирает cpio — таблицы встраивает хук. У dracut такого хука нет,
поэтому команда создаёт `acpi_override.cpio` в каталоге репозитория.

### 2a. mkinitcpio (Arch, CachyOS и производные)

В mkinitcpio есть хук `acpi_override`. Он помещает все `*.aml` из
`/etc/initcpio/acpi_override/` в несжатое начало initramfs, которое ядро читает первым.
Это начало есть и в обычном initramfs, и в UKI, поэтому отдельная строка `initrd=` не
нужна ни в одном из случаев.

```
# /etc/mkinitcpio.conf: добавьте acpi_override в существующую строку HOOKS (после microcode)
# Строка ниже — пример по умолчанию в CachyOS; остальные хуки оставьте как есть
HOOKS=(base systemd autodetect microcode acpi_override kms modconf block keyboard sd-vconsole plymouth filesystems)

sudo mkinitcpio -P          # пересобрать обычный initramfs
```

Дистрибутивы с UKI собирают его тем же инструментом: в CachyOS это делает
`limine-mkinitcpio-hook`, который вызывает mkinitcpio, вывод хука попадает в образ
автоматически, команда пересборки — `sudo limine-update`. Дистрибутивы, которые собирают
UKI через аналогичный хук, ведут себя так же.

Если каталог пуст, хук останавливает сборку с сообщением `No ACPI table override files
found`: пустой каталог означает, что на этой загрузке патч не будет загружен.

<details>
<summary><b>2b. dracut и другие генераторы initramfs (Fedora, openSUSE и т.п.)</b></summary>


В dracut аналогичного хука нет, поэтому таблица загружается отдельным несжатым cpio
перед initrd. Сборка:

```
sudo ./rebuild_patch.sh --minimal
sudo cp acpi_override.cpio /boot/
```

`acpi_override.cpio` должен быть указан **перед** основным initramfs. Для каждого
загрузчика это делается по-своему:

| Загрузчик | Файл | Добавляемая запись | Применение |
|---|---|---|---|
| GRUB | `/etc/default/grub` | `GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"` | как в шаге 1 (по дистрибутиву) |
| systemd-boot | `/boot/loader/entries/*.conf` | `initrd /acpi_override.cpio` перед существующей строкой `initrd` | ничего |
| Limine | `/etc/default/limine` | `initrd=/acpi_override.cpio` в начале `KERNEL_CMDLINE[default]+=` | `sudo limine-update` |

UKI, собранные хуком, обрабатываются по 2a и этот cpio не используют. Указывать cpio
перед основным initramfs нужно только при ручной сборке образа.

Путь в `GRUB_EARLY_INITRD_LINUX_CUSTOM` задаётся относительно `/boot`. На системах, где
`/boot` является разделом EFI, используется та же относительная форма.

В дистрибутивах с записями BLS (Fedora) `GRUB_EARLY_INITRD_LINUX_CUSTOM` может не
сработать; поместите cpio в начало списка initrd так, как это принято в дистрибутиве.

При включённом Secure Boot отдельно загружаемый cpio не входит в подпись initramfs,
поэтому для этого файла нужна собственная подпись или контрольная сумма в конфигурации
загрузчика. Поэтому там, где это возможно, предпочтителен хук из 2a.

</details>

## Шаг 3 — службы systemd

| Юнит | Назначение |
|---|---|
| `lecoo-wake-guard.service` | отключает пробуждение от i8042, GPP2, XHC0/1/3/4, NHI0 |
| `lecoo-nic-unbind.service` | отвязывает `r8169` при выключении |

Настройки `/proc/acpi/wakeup` не сохраняются после перезагрузки: источники включаются
снова при каждой загрузке, и первая служба отключает их. Вторая запускается при
выключении, когда сессия уже завершена, а ядро ещё не выключило драйверы. Во время
обычной работы сеть доступна.

Ещё два юнита ведут журнал: `lecoo-acpi-log` записывает загрузки, сны и
выключения в `/var/log/lecoo-acpi/events.jsonl`, а `lecoo-acpi-log report` выводит их
таблицей.

```
sudo install -m755 patches/bios-0x01072009/systemd/lecoo-wake-guard.sh \
                   patches/bios-0x01072009/systemd/lecoo-nic-unbind.sh /usr/local/sbin/
sudo install -m755 patches/bios-0x01072009/systemd/50-lecoo-acpi-log \
                   /usr/lib/systemd/system-sleep/
sudo install -m644 patches/bios-0x01072009/systemd/*.service /etc/systemd/system/
sudo install -m755 tools/lecoo-acpi-log.py /usr/local/sbin/lecoo-acpi-log

sudo systemctl daemon-reload
sudo systemctl enable --now lecoo-wake-guard lecoo-nic-unbind \
                            lecoo-acpi-log lecoo-acpi-log-shutdown
```

Эти юниты рассчитаны на systemd и интерфейс хуков `/usr/lib/systemd/system-sleep`.
В системе без systemd применима только таблица ACPI из шага 2.

## Проверка

После следующей загрузки:

```
journalctl -b -k | grep "Table Upgrade"     # одна строка: SSDT- AMD-CPMGPIO0
ls /sys/bus/acpi/devices/ | grep PTCH       # пусто: DSDT не подменяется
grep -E "XHC|NHI|GPP2" /proc/acpi/wakeup    # везде *disabled
```

Выполните один сон и проверьте счётчики:

```
./tools/ec-probe.sh wake
```

Команда записывает счётчики ACPI, переводит машину в сон и после пробуждения выводит
разницу. Если счётчики не изменились и машина просыпается только от нажатия клавиши,
таблица действует.

## Откат

<details>
<summary>Команды</summary>

```
# mkinitcpio (шаг 2a)
sudo sed -i 's/ acpi_override//' /etc/mkinitcpio.conf
sudo rm -f /etc/initcpio/acpi_override/*.aml
sudo mkinitcpio -P          # для UKI: sudo limine-update

# отдельный cpio (шаг 2b)
sudo rm -f /boot/acpi_override.cpio
# удалить запись, добавленную в шаге 2b, и пересобрать конфигурацию как в шаге 1

sudo systemctl disable --now lecoo-wake-guard lecoo-nic-unbind \
                            lecoo-acpi-log lecoo-acpi-log-shutdown
```

</details>

## Лицензия

Таблицы ACPI принадлежат их владельцам. Изменения предоставлены только для
совместимости и ремонта.
