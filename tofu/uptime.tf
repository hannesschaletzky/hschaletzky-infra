# Externe Erreichbarkeit (UptimeRobot): prüft von außen alle 5 Minuten, ob die Seiten antworten,
# und meldet Ausfälle per Pushover und E-Mail. Ergänzt Beszel, das auf dem Server selbst läuft und
# einen Totalausfall nicht melden kann.
#
# Die Pushover-Integration ist von Hand in UptimeRobot angelegt (Integrations & Team), damit der
# Pushover-Schlüssel nicht im State landet. Hier wird sie nur über Name und Typ gefunden.
data "uptimerobot_integration" "pushover" {
  name = var.uptimerobot_pushover_name
  type = "pushover"
}

data "uptimerobot_alert_contacts" "email" {
  type   = "email"
  status = "active"
}

locals {
  # Name im Alarm → Adresse. Zertifikats-Prüfungen gibt es erst im bezahlten Plan; Caddy erneuert
  # die Zertifikate ohnehin 30 Tage vor Ablauf, und ein abgelaufenes fällt hier als Ausfall auf.
  uptime_monitore = {
    "Website"              = "https://hschaletzky.com"
    "Blog"                 = "https://blog.hschaletzky.com"
    "Beispiel Tischlerei"  = "https://tischlerei-mustermann.hschaletzky.com"
    "Beispiel Sportverein" = "https://sv-musterstadt.hschaletzky.com"
    "Beispiel Physio"      = "https://physio-musterfrau.hschaletzky.com"
    "Plausible"            = "https://stats.hschaletzky.com/api/health"
    "Beszel"               = "https://monitor.hschaletzky.com/api/health"
  }

  # Der kostenlose Plan erlaubt nur sofortige Benachrichtigung ohne Wiederholung (0/0)
  uptime_kontakte = concat(
    [{ alert_contact_id = data.uptimerobot_integration.pushover.id, threshold = 0, recurrence = 0 }],
    [for id in data.uptimerobot_alert_contacts.email.ids : { alert_contact_id = id, threshold = 0, recurrence = 0 }],
  )
}

resource "uptimerobot_monitor" "seiten" {
  for_each = local.uptime_monitore

  name     = each.key
  type     = "HTTP"
  url      = each.value
  interval = 300
  timeout  = 30

  assigned_alert_contacts = local.uptime_kontakte
}
