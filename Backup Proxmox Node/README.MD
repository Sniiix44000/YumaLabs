import pypandoc

readme = r'''# Proxmox Node Backup

Script Bash permettant de sauvegarder la **configuration complète d'un nœud Proxmox VE**, sans sauvegarder les disques des VM ou des conteneurs.

Le script est conçu pour être utilisé de manière autonome via `cron` ou `systemd timer`.

---

## Fonctionnalités

Le script sauvegarde notamment :

- Configuration Proxmox VE
- Cluster Proxmox
- Base SQLite `config.db`
- Dump SQLite de `config.db`
- Vérification d'intégrité SQLite
- Configuration réseau
- Interfaces réseau et routage
- Configuration iSCSI
- Sessions iSCSI
- Configuration multipath
- État multipath
- Configuration APT
- Certificats SSL
- Certificats privés Proxmox
- Configuration SSH
- Clés SSH
- Configuration systemd
- Configuration kernel / modules
- `sysctl`
- `fstab`
- Cron
- Logrotate
- Inventaire matériel
- CPU / RAM
- PCI
- Disques / contrôleurs
- LVM
- ZFS si présent
- Ceph si présent
- Services systemd
- Paquets installés
- Paquets installés manuellement
- État des VM et CT

Le script génère également :

- Un manifeste de sauvegarde
- Une somme SHA256
- Une vérification SHA256
- Une vérification d'intégrité ZSTD
- Une vérification de lecture de l'archive TAR
- Des logs locaux
- Des logs syslog/journald
- Une notification mail optionnelle
- Une rotation automatique des anciennes sauvegardes
- Un transfert distant optionnel

---

# Important

## Ce qui n'est PAS sauvegardé

Le script sauvegarde la **configuration du nœud**, pas les données des VM/CT.

Ne sont notamment pas inclus :

- Disques VM
- Disques CT
- Images ISO
- Templates
- Volumes LVM utilisés par les VM
- Volumes ZFS utilisés par les VM
- Données Ceph des VM

Cette sauvegarde ne remplace donc **pas une sauvegarde Veeam, PBS ou autre solution de sauvegarde des VM**.

Elle permet principalement de reconstruire rapidement la configuration d'un nœud Proxmox.

---

# Prérequis

Le script doit être exécuté avec les privilèges `root`.

Exemple :

```bash
sudo -i
```

Les commandes suivantes sont utilisées :

```text
tar
zstd
sha256sum
find
hostname
date
mountpoint
sqlite3
logger
mktemp
cp
tee
```

Selon la configuration du serveur, les commandes suivantes peuvent également être utilisées :

```text
pveversion
pvesh
qm
pct
lspci
lsblk
lscpu
pvs
vgs
lvs
iscsiadm
multipath
zpool
zfs
ceph
```

Les commandes optionnelles ne provoquent pas d'échec si elles ne sont pas présentes.

---

# Installation

Copier le script sur le nœud Proxmox.

Exemple :

```bash
mkdir -p /usr/local/sbin

cp proxmox-node-backup.sh /usr/local/sbin/proxmox-node-backup.sh

chmod 750 /usr/local/sbin/proxmox-node-backup.sh
chown root:root /usr/local/sbin/proxmox-node-backup.sh
```

Ou, directement :

```bash
install -o root -g root -m 750 proxmox-node-backup.sh \
    /usr/local/sbin/proxmox-node-backup.sh
```

Vérifier :

```bash
ls -l /usr/local/sbin/proxmox-node-backup.sh
```

Le résultat doit être similaire à :

```text
-rwxr-x--- 1 root root ... /usr/local/sbin/proxmox-node-backup.sh
```

---

# Configuration

La configuration se trouve directement au début du script.

## Répertoire de sauvegarde

Par défaut :

```bash
BACKUP_DIR="/var/backups/proxmox-node"
```

Créer le répertoire si nécessaire :

```bash
mkdir -p /var/backups/proxmox-node
chmod 700 /var/backups/proxmox-node
```

---

## Rétention

Par défaut :

```bash
KEEP_DAYS=7
```

Les sauvegardes plus anciennes sont automatiquement supprimées.

Exemple pour conserver 30 jours :

```bash
KEEP_DAYS=30
```

---

## Compression

Le format utilisé est :

```text
TAR + ZSTD
```

Exemple :

```text
proxmox-node_pve01_20261006_102500.tar.zst
```

### Threads ZSTD

Par défaut :

```bash
ZSTD_THREADS=0
```

`0` signifie que ZSTD utilise son comportement automatique pour déterminer le nombre de threads.

Le script ne force donc pas un nombre fixe de CPU.

### Niveau de compression

Par défaut :

```bash
ZSTD_LEVEL=3
```

Le niveau 3 constitue un compromis entre :

- vitesse
- consommation CPU
- taille de l'archive

Pour augmenter la compression :

```bash
ZSTD_LEVEL=6
```

Pour privilégier la vitesse :

```bash
ZSTD_LEVEL=1
```

---

# Notifications

Trois modes sont disponibles :

```text
none
failure
always
```

## Aucune notification

```bash
NOTIFICATION_MODE="none"
```

## Notification uniquement en cas d'échec

Configuration recommandée :

```bash
NOTIFICATION_MODE="failure"
```

## Notification à chaque exécution

```bash
NOTIFICATION_MODE="always"
```

## Adresse de notification

Configurer :

```bash
MAIL_TO="admin@example.com"
```

Le script utilise par défaut :

```bash
SENDMAIL="/usr/sbin/sendmail"
```

Un MTA fonctionnel doit donc être présent sur le serveur si les notifications mail sont activées.

---

# Transfert distant

Le transfert distant est désactivé par défaut :

```bash
REMOTE_ENABLED=false
```

Pour l'activer :

```bash
REMOTE_ENABLED=true
```

Le mode SSH utilise :

```bash
REMOTE_TYPE="ssh"
REMOTE_HOST="backup01.example.local"
REMOTE_USER="root"
REMOTE_PATH="/backup/proxmox"
```

Il est recommandé d'utiliser une authentification SSH par clé plutôt qu'un mot de passe.

---

# Notice d'utilisation

## 1. Première installation

Installer le script :

```bash
install -o root -g root -m 750 proxmox-node-backup.sh \
    /usr/local/sbin/proxmox-node-backup.sh
```

Vérifier :

```bash
ls -l /usr/local/sbin/proxmox-node-backup.sh
```

---

## 2. Vérifier les prérequis

Avant la première exécution :

```bash
command -v tar
command -v zstd
command -v sha256sum
command -v sqlite3
command -v logger
```

Vérifier également la version de Proxmox :

```bash
pveversion -v
```

---

## 3. Préparer le répertoire de sauvegarde

Par défaut :

```text
/var/backups/proxmox-node
```

Créer le répertoire :

```bash
mkdir -p /var/backups/proxmox-node
chmod 700 /var/backups/proxmox-node
```

Vérifier :

```bash
ls -ld /var/backups/proxmox-node
```

---

## 4. Configurer le script

Éditer le fichier :

```bash
nano /usr/local/sbin/proxmox-node-backup.sh
```

Vérifier au minimum :

```bash
BACKUP_DIR="/var/backups/proxmox-node"
KEEP_DAYS=7
ZSTD_THREADS=0
ZSTD_LEVEL=3
NOTIFICATION_MODE="failure"
MAIL_TO=""
```

Si un stockage distant est utilisé :

```bash
REMOTE_ENABLED=true
REMOTE_TYPE="ssh"
REMOTE_HOST="backup01.example.local"
REMOTE_USER="root"
REMOTE_PATH="/backup/proxmox"
```

---

# 5. Première exécution manuelle

La première exécution doit toujours être réalisée manuellement.

Lancer :

```bash
/usr/local/sbin/proxmox-node-backup.sh
```

À la fin, vérifier le code retour :

```bash
echo $?
```

Résultat attendu :

```text
0
```

Un code différent de `0` indique que la sauvegarde doit être considérée comme en échec.

---

# 6. Vérifier la sauvegarde créée

Lister les sauvegardes :

```bash
ls -lah /var/backups/proxmox-node/
```

Une sauvegarde complète doit produire deux fichiers :

```text
proxmox-node_<hostname>_<date>.tar.zst
proxmox-node_<hostname>_<date>.tar.zst.sha256
```

Exemple :

```text
proxmox-node_pve01_20261006_020000.tar.zst
proxmox-node_pve01_20261006_020000.tar.zst.sha256
```

---

# 7. Vérification SHA256

Se placer dans le répertoire :

```bash
cd /var/backups/proxmox-node
```

Puis :

```bash
sha256sum -c proxmox-node_pve01_20261006_020000.tar.zst.sha256
```

Résultat attendu :

```text
proxmox-node_pve01_20261006_020000.tar.zst: OK
```

Si le résultat n'est pas `OK`, la sauvegarde doit être considérée comme invalide.

---

# 8. Vérification de l'archive ZSTD

Tester l'intégrité de la compression :

```bash
zstd -t proxmox-node_pve01_20261006_020000.tar.zst
```

Résultat attendu :

```text
No errors detected
```

---

# 9. Vérification du contenu TAR

Lister le contenu sans extraire l'archive :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst | tar -tf -
```

Pour simplement vérifier que la lecture complète fonctionne :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst | tar -tf - >/dev/null
```

Le code retour doit être :

```bash
echo $?
```

Résultat attendu :

```text
0
```

---

# 10. Consulter le contenu d'un fichier précis

Il est possible d'extraire uniquement un fichier sans décompresser toute l'archive.

Exemple :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst \
    | tar -xOf - etc/hostname
```

Pour afficher la configuration réseau :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst \
    | tar -xOf - etc/network/interfaces
```

Pour consulter le dump SQLite :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst \
    | tar -xOf - pve-cluster/config.dump.sql
```

---

# 11. Extraire une sauvegarde complète

Créer un répertoire temporaire :

```bash
mkdir -p /tmp/proxmox-node-restore
```

Extraire l'archive :

```bash
zstd -dc proxmox-node_pve01_20261006_020000.tar.zst \
    | tar -x -C /tmp/proxmox-node-restore
```

Vérifier :

```bash
find /tmp/proxmox-node-restore -maxdepth 2 -type f | sort
```

**Attention :**

Cette opération extrait les fichiers dans un répertoire de travail.

Il ne faut pas recopier automatiquement l'intégralité du contenu vers `/`.

Une restauration Proxmox doit être réalisée fichier par fichier ou composant par composant après analyse du contexte.

---

# 12. Consulter les logs

Le log principal est :

```text
/var/log/proxmox-node-backup/backup.log
```

Afficher les dernières lignes :

```bash
tail -100 /var/log/proxmox-node-backup/backup.log
```

Suivre l'exécution en temps réel :

```bash
tail -f /var/log/proxmox-node-backup/backup.log
```

Rechercher les erreurs :

```bash
grep -Ei "error|failed|failure" \
    /var/log/proxmox-node-backup/backup.log
```

---

# 13. Consulter journald

Le script utilise également le journal système.

Afficher les événements :

```bash
journalctl -t proxmox-node-backup
```

Afficher uniquement la journée courante :

```bash
journalctl -t proxmox-node-backup --since today
```

Suivre en temps réel :

```bash
journalctl -f -t proxmox-node-backup
```

---

# 14. Tester les notifications

Pour tester une notification, modifier temporairement :

```bash
NOTIFICATION_MODE="always"
```

Puis exécuter :

```bash
/usr/local/sbin/proxmox-node-backup.sh
```

Vérifier la réception du message.

Après le test, remettre :

```bash
NOTIFICATION_MODE="failure"
```

---

# 15. Tester le comportement en cas d'échec

Il est recommandé de tester le mécanisme d'alerte avant de mettre le script en production.

Une méthode consiste à utiliser temporairement un répertoire de sauvegarde inaccessible ou à provoquer volontairement une erreur contrôlée dans un environnement de test.

Après le test, vérifier :

```bash
echo $?
```

Le script doit retourner une valeur différente de :

```text
0
```

Vérifier également :

```bash
journalctl -t proxmox-node-backup --since "10 minutes ago"
```

et :

```bash
tail -50 /var/log/proxmox-node-backup/backup.log
```

---

# 16. Mettre en place l'exécution automatique

Une fois l'exécution manuelle validée, l'automatisation peut être activée.

## Avec systemd timer

Créer :

```text
/etc/systemd/system/proxmox-node-backup.service
```

Contenu :

```ini
[Unit]
Description=Proxmox Node Configuration Backup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxmox-node-backup.sh
User=root
```

Créer :

```text
/etc/systemd/system/proxmox-node-backup.timer
```

Contenu :

```ini
[Unit]
Description=Daily Proxmox Node Configuration Backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Recharger systemd :

```bash
systemctl daemon-reload
```

Activer le timer :

```bash
systemctl enable --now proxmox-node-backup.timer
```

---

# 17. Vérifier le timer

Afficher l'état :

```bash
systemctl status proxmox-node-backup.timer
```

Lister les prochaines exécutions :

```bash
systemctl list-timers proxmox-node-backup.timer
```

Le timer doit apparaître comme `active (waiting)`.

---

# 18. Tester immédiatement le service systemd

Avant d'attendre l'heure planifiée :

```bash
systemctl start proxmox-node-backup.service
```

Vérifier :

```bash
systemctl status proxmox-node-backup.service
```

Consulter le journal :

```bash
journalctl -u proxmox-node-backup.service -n 100
```

Vérifier la sauvegarde :

```bash
ls -lht /var/backups/proxmox-node/
```

---

# 19. Planification avec cron

Une alternative à systemd timer est cron.

Éditer :

```bash
crontab -e
```

Exemple d'exécution tous les jours à 02:00 :

```cron
0 2 * * * /usr/local/sbin/proxmox-node-backup.sh
```

Il est recommandé de ne choisir **qu'un seul** mécanisme de planification afin d'éviter deux exécutions simultanées.

---

# 20. Vérifier le fonctionnement quotidien

Contrôle rapide :

```bash
systemctl list-timers proxmox-node-backup.timer
```

Puis :

```bash
ls -lht /var/backups/proxmox-node/ | head
```

Et :

```bash
tail -30 /var/log/proxmox-node-backup/backup.log
```

Le fichier le plus récent doit correspondre à la dernière exécution.

---

# 21. Vérifier la rotation

La rotation utilise :

```bash
KEEP_DAYS=7
```

Pour vérifier les anciennes sauvegardes :

```bash
find /var/backups/proxmox-node \
    -type f \
    -printf '%TY-%Tm-%Td %TH:%TM %p\n' \
    | sort
```

Les sauvegardes dépassant la durée de rétention sont supprimées automatiquement par le script.

---

# 22. Vérifier l'espace disque

La sauvegarde doit être surveillée afin d'éviter que le répertoire de backup remplisse le disque système.

Vérifier :

```bash
df -h /var/backups/proxmox-node
```

Voir la taille utilisée :

```bash
du -sh /var/backups/proxmox-node
```

Voir la taille de chaque sauvegarde :

```bash
du -h /var/backups/proxmox-node/*
```

---

# 23. En cas d'échec

Procéder dans cet ordre.

### Étape 1 : vérifier le service

```bash
systemctl status proxmox-node-backup.service
```

### Étape 2 : consulter le journal

```bash
journalctl -u proxmox-node-backup.service -n 200
```

### Étape 3 : consulter le log applicatif

```bash
tail -200 /var/log/proxmox-node-backup/backup.log
```

### Étape 4 : rechercher les erreurs

```bash
grep -Ei "error|failed|failure" \
    /var/log/proxmox-node-backup/backup.log
```

### Étape 5 : vérifier l'espace disque

```bash
df -h
```

### Étape 6 : vérifier les dépendances

```bash
command -v tar
command -v zstd
command -v sqlite3
command -v sha256sum
```

### Étape 7 : relancer manuellement

```bash
/usr/local/sbin/proxmox-node-backup.sh
```

---

# Base Proxmox et SQLite

La base suivante est sauvegardée :

```text
/var/lib/pve-cluster/config.db
```

Un dump SQLite est également généré :

```text
pve-cluster/config.dump.sql
```

Le script exécute :

```sql
PRAGMA integrity_check;
```

afin de vérifier l'intégrité de la base SQLite avant de considérer la sauvegarde comme valide.

---

# Configuration réseau

Les éléments suivants sont sauvegardés lorsqu'ils existent :

```text
/etc/network
/etc/hosts
/etc/hostname
/etc/resolv.conf
/etc/NetworkManager
/etc/systemd/resolved.conf
```

Le script collecte également :

```bash
ip -details address
ip -details link
ip route
ip rule
```

Ces informations permettent de reconstruire l'état réseau du serveur.

---

# iSCSI

Les configurations iSCSI sont sauvegardées notamment depuis :

```text
/etc/iscsi
```

Le script collecte également les sessions iSCSI actives lorsque `iscsiadm` est disponible :

```bash
iscsiadm -m session
```

---

# Multipath

La configuration suivante est sauvegardée :

```text
/etc/multipath.conf
/etc/multipath
```

L'état multipath est également collecté :

```bash
multipath -ll
```

---

# SSH

Les éléments SSH sont sauvegardés :

```text
/etc/ssh
/root/.ssh
```

Cela inclut notamment :

- configuration SSH
- clés SSH
- `authorized_keys`
- `known_hosts`
- configuration serveur/client

---

# Certificats

Les certificats système sont sauvegardés :

```text
/etc/ssl/certs
/etc/ssl/private
```

Les certificats privés Proxmox sont également sauvegardés lorsque présents :

```text
/etc/pve/nodes/<hostname>/pve-ssl.pem
/etc/pve/nodes/<hostname>/pve-ssl.key
```

Ces fichiers sont sensibles.

Les sauvegardes doivent donc être stockées dans un emplacement sécurisé avec des permissions restrictives.

---

# Inventaire matériel

Le script collecte notamment :

```text
CPU
RAM
PCI
Disques
Contrôleurs
Interfaces réseau
LVM
ZFS
Ceph
Modules kernel
```

Exemples de commandes :

```bash
lscpu
lspci -nnk
lsblk
pvs
vgs
lvs
lsmod
```

Cela permet d'avoir une photographie du matériel et de l'état du système au moment de la sauvegarde.

---

# Structure interne

L'archive contient une structure permettant de distinguer les différentes catégories.

Exemple :

```text
etc/
var/
inventory/
manifest/
pve-cluster/
```

Le manifeste permet notamment d'identifier :

- le serveur
- la date de sauvegarde
- la version du script
- la version Proxmox
- le nombre de threads ZSTD configuré
- le contenu sauvegardé
- le fait que les disques VM/CT ne sont pas inclus

---

# Stratégie de sauvegarde

La sauvegarde de configuration du nœud doit être considérée comme une sauvegarde complémentaire.

Elle ne remplace pas les sauvegardes des VM et CT.

Exemple :

```text
                    ┌─────────────────────┐
                    │    Proxmox Node     │
                    └──────────┬──────────┘
                               │
             ┌─────────────────┴─────────────────┐
             │                                   │
             ▼                                   ▼
   Configuration Node                    VM / CT Backup
             │                                   │
             ▼                                   ▼
 proxmox-node-backup.sh                       Veeam / PBS
             │
             ▼
      Stockage distant
```

L'objectif est de pouvoir reconstruire rapidement un nœud Proxmox en cas de :

- panne matérielle
- remplacement du serveur
- corruption du système
- erreur de configuration
- problème réseau
- problème iSCSI
- problème multipath
- incident cluster

---

# Restauration

Le script n'effectue volontairement **aucune restauration automatique**.

La restauration doit être effectuée avec précaution, car certains fichiers sont directement liés au nœud Proxmox et à son identité.

Avant toute restauration :

1. Identifier la version Proxmox.
2. Identifier le nom du nœud.
3. Vérifier la configuration cluster.
4. Vérifier le stockage.
5. Vérifier le réseau.
6. Vérifier iSCSI.
7. Vérifier multipath.
8. Vérifier les certificats.
9. Vérifier SSH.
10. Vérifier `/etc/pve`.

Ne jamais restaurer aveuglément l'intégralité de `/etc/pve` sur un nœud différent.

---

# Test de restauration

Une sauvegarde n'est considérée comme réellement fiable que si elle peut être restaurée.

Il est recommandé de tester périodiquement :

```bash
sha256sum -c *.sha256
```

Puis :

```bash
zstd -t *.tar.zst
```

Et enfin :

```bash
zstd -dc *.tar.zst | tar -tf - >/dev/null
```

Un test de restauration complet peut ensuite être réalisé sur un serveur Proxmox de test.

---

# Sécurité

Les sauvegardes contiennent des informations sensibles.

Elles peuvent notamment contenir :

- clés SSH
- clés privées
- certificats
- configuration réseau
- configuration Proxmox
- informations d'infrastructure
- configuration d'authentification

Il est donc recommandé de :

1. Limiter les permissions du répertoire de sauvegarde.
2. Ne pas exposer le répertoire de sauvegarde via HTTP.
3. Utiliser un stockage distant sécurisé.
4. Chiffrer les sauvegardes si elles quittent l'infrastructure.
5. Limiter les accès SSH au serveur de sauvegarde.
6. Ne pas conserver les sauvegardes uniquement sur le nœud Proxmox.

---

# Désactiver temporairement les sauvegardes

Pour arrêter la planification systemd :

```bash
systemctl disable --now proxmox-node-backup.timer
```

Vérifier :

```bash
systemctl status proxmox-node-backup.timer
```

---

# Réactiver les sauvegardes

```bash
systemctl enable --now proxmox-node-backup.timer
```

Puis :

```bash
systemctl list-timers proxmox-node-backup.timer
```

---

# Suppression de l'installation

Arrêter le timer :

```bash
systemctl disable --now proxmox-node-backup.timer
```

Supprimer les unités :

```bash
rm -f /etc/systemd/system/proxmox-node-backup.service
rm -f /etc/systemd/system/proxmox-node-backup.timer
```

Recharger systemd :

```bash
systemctl daemon-reload
```

Supprimer le script :

```bash
rm -f /usr/local/sbin/proxmox-node-backup.sh
```

Les sauvegardes existantes ne sont pas supprimées automatiquement.

---

# Procédure recommandée de mise en production

La procédure suivante est recommandée lors du déploiement sur un nouveau nœud.

### 1. Installer le script

```bash
install -o root -g root -m 750 proxmox-node-backup.sh \
    /usr/local/sbin/proxmox-node-backup.sh
```

### 2. Vérifier la configuration

```bash
nano /usr/local/sbin/proxmox-node-backup.sh
```

### 3. Vérifier les prérequis

```bash
command -v tar
command -v zstd
command -v sqlite3
command -v sha256sum
```

### 4. Lancer une sauvegarde manuelle

```bash
/usr/local/sbin/proxmox-node-backup.sh
```

### 5. Vérifier le code retour

```bash
echo $?
```

### 6. Vérifier l'archive

```bash
ls -lh /var/backups/proxmox-node/
```

### 7. Vérifier SHA256

```bash
sha256sum -c /var/backups/proxmox-node/*.sha256
```

### 8. Vérifier ZSTD

```bash
zstd -t /var/backups/proxmox-node/*.tar.zst
```

### 9. Vérifier le contenu

```bash
zstd -dc /var/backups/proxmox-node/*.tar.zst \
    | tar -tf - >/dev/null
```

### 10. Tester les notifications

Configurer temporairement :

```bash
NOTIFICATION_MODE="always"
```

Puis lancer une sauvegarde.

### 11. Activer le timer

```bash
systemctl enable --now proxmox-node-backup.timer
```

### 12. Vérifier la planification

```bash
systemctl list-timers proxmox-node-backup.timer
```

### 13. Documenter l'emplacement de la sauvegarde

Documenter :

```text
Serveur :
Emplacement local :
Stockage distant :
Rétention :
Fréquence :
Adresse de notification :
Date du dernier test :
```

---

# Contrôle périodique recommandé

Une fois par mois, effectuer au minimum :

```bash
systemctl status proxmox-node-backup.timer
```

```bash
ls -lht /var/backups/proxmox-node/
```

```bash
sha256sum -c /var/backups/proxmox-node/*.sha256
```

```bash
zstd -t /var/backups/proxmox-node/*.tar.zst
```

```bash
df -h /var/backups/proxmox-node
```

Vérifier également que les notifications fonctionnent.

Au minimum une fois par trimestre, effectuer un **test réel de restauration sur un environnement de test**.

---

# Checklist de validation

## Installation

- [ ] Script installé dans `/usr/local/sbin`
- [ ] Propriétaire `root:root`
- [ ] Permissions `750`
- [ ] Prérequis disponibles
- [ ] Répertoire de sauvegarde créé

## Configuration

- [ ] Rétention configurée
- [ ] Compression configurée
- [ ] `ZSTD_THREADS=0`
- [ ] Niveau ZSTD vérifié
- [ ] Notification configurée
- [ ] Stockage distant configuré si nécessaire

## Première sauvegarde

- [ ] Exécution manuelle réussie
- [ ] Code retour `0`
- [ ] Archive créée
- [ ] Fichier SHA256 créé
- [ ] SHA256 validé
- [ ] Archive ZSTD validée
- [ ] Contenu TAR lisible
- [ ] Logs présents
- [ ] Notification reçue

## Automatisation

- [ ] Service systemd créé
- [ ] Timer systemd créé
- [ ] Timer activé
- [ ] Exécution manuelle du service validée
- [ ] Prochaine exécution planifiée vérifiée

## Exploitation

- [ ] Rétention vérifiée
- [ ] Espace disque surveillé
- [ ] Sauvegarde distante vérifiée
- [ ] Test de restauration réalisé
- [ ] Procédure de restauration documentée

---

# Architecture

Le script reste volontairement indépendant de l'interface de gestion des tâches Proxmox.

Il n'utilise pas :

- `fork_worker()`
- `PVE::Notify`
- les tâches Proxmox
- une intégration interne à l'API Proxmox

Il fonctionne comme un outil système classique :

```text
systemd timer / cron
        │
        ▼
proxmox-node-backup.sh
        │
        ├── Collecte configuration
        ├── Collecte inventaire
        ├── SQLite dump
        ├── SQLite integrity check
        ├── TAR
        ├── ZSTD
        ├── SHA256
        ├── Vérification archive
        ├── Rotation
        └── Notification
```

Cette approche permet de conserver un script simple, portable et indépendant des évolutions de l'interface interne de Proxmox.

---

# Code retour

Le script retourne :

```text
0
```

si la sauvegarde est réussie.

Une valeur différente de `0` indique une erreur.

Exemple :

```bash
/usr/local/sbin/proxmox-node-backup.sh
echo $?
```

---

# Exploitation rapide

Pour vérifier rapidement la dernière sauvegarde :

```bash
ls -lht /var/backups/proxmox-node/
```

Pour vérifier le dernier log :

```bash
tail -100 /var/log/proxmox-node-backup/backup.log
```

Pour rechercher les erreurs :

```bash
grep -Ei "error|failed|failure" \
    /var/log/proxmox-node-backup/backup.log
```

---

# Version

**Projet :** Proxmox Node Backup  
**Version :** v1  
**Auteur :** Alvin ARTUS  
**Société :** Yumaiia

---

# Licence

Usage interne / infrastructure Yumaiia.

Toute redistribution ou adaptation doit être validée selon les règles internes.
'''

path = "/mnt/data/README.md"
pypandoc.convert_text(readme, 'md', format='md', outputfile=path, extra_args=['--standalone'])
print(path)
