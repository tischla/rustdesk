# Serverprofile (mehrere Vermittlungsserver) – Branch `feature/server-profiles`

## Prinzip

| Komponente | Server |
|---|---|
| **Dienst** (eingehende Verbindungen, eigene ID) | genau **einer**, wie bisher: *Einstellungen → Netzwerk → ID-/Relay-Server* (`custom-rendezvous-server`, `key` in `RustDesk2.toml`) |
| **Client** (ausgehende Verbindungen) | **pro Verbindung** wählbar über Serverprofile |

Profile liegen in der benutzerbezogenen `RustDesk_local.toml` (Option `server-profiles`, JSON),
die der Dienst nicht liest. Änderungen an Profilen berühren den Dienst also nie, und der Dienst
läuft unabhängig davon weiter, ob bzw. welcher Client gerade offen ist.

Mehrere Sitzungen über verschiedene Server können gleichzeitig laufen, weil jede Sitzung ihren
Server beim Verbindungsaufbau festlegt.

## Profil wählen

* **Explizit:** `<ID>@<Profil>`, z. B. `123456789@pwe`, `123456789/r@home` (Relay erzwingen).
  Funktioniert in der ID-Eingabe, mit `rustdesk --connect 123456789@pwe` und über `rustdesk://`-Links.
* **Auswahlfeld** neben *Verbinden*: setzt `default-server-profile`. Eine reine ID wird dann beim
  Verbinden zu `<ID>@<Profil>` ergänzt. „Server des Dienstes (Standard)" = bisheriges Verhalten.
* Einträge in „Zuletzt verwendet" werden als `<ID>@<Profil>` gespeichert und bleiben damit an das
  Profil gebunden – auch wenn Host/Key des Profils später geändert werden.

Intern wird `<ID>@<Profil>` zu RustDesks bestehender Syntax `<ID>@<Host>?key=<Key>` aufgelöst
(`src/server_profiles.rs`); Verbindungsaufbau, Relay-Vergabe (kommt vom jeweiligen hbbs) und
Trusted-Devices-Namespace nutzen den vorhandenen `other_server`-Pfad.

## Profil anlegen

*Einstellungen → Netzwerk → Serverprofile → Serverprofile verwalten*, oder direkt in
`RustDesk_local.toml`:

```toml
[options]
server-profiles = '[{"name":"pwe","host":"rd.pwe-system.at","key":"<id_ed25519.pub>","description":"Firma"},{"name":"home","host":"my.nebukad.net","key":"<id_ed25519.pub>"}]'
default-server-profile = 'pwe'
```

Name: `[A-Za-z0-9_-]{1,32}`. Host: `host` oder `host:port` (Standard 21116).

## Einschränkungen

* Profile steuern nur ID-Server + Key. Relay kommt vom jeweiligen hbbs (`hbbs -r …` bzw. Standard).
  API-Server/Adressbuch/Login bleiben an der globalen Konfiguration.
* Gegenstelle „Seiten wechseln": die Rückverbindung ignoriert das Standardprofil und bleibt auf dem Server des Dienstes.
* Bereits gespeicherte Peers mit reiner ID werden bei gesetztem Standardprofil als neuer Eintrag
  `<ID>@<Profil>` geführt (gespeichertes Passwort ggf. neu eingeben).
* UI nur Desktop-Flutter. Mobile/Sciter: Syntax `<ID>@<Profil>` funktioniert, sobald Profile in
  `RustDesk_local.toml` stehen, es gibt aber keine Verwaltungsoberfläche.
* Eine ID, die einem Profilnamen gleicht (z. B. `@localhost` mit Profil `localhost`), wird als Profil interpretiert.
