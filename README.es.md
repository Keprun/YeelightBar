<p align="center">
  <img src=".github/banner.svg" alt="YeelightBar" width="840">
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-0A0C0A?style=flat-square&logo=apple&logoColor=44D62C&labelColor=0A0C0A">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-44D62C?style=flat-square&logo=swift&logoColor=white&labelColor=0A0C0A">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="LAN only" src="https://img.shields.io/badge/cloud-none%20%C2%B7%20LAN%20only-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="Stars" src="https://img.shields.io/github/stars/Keprun/YeelightBar?style=flat-square&labelColor=0A0C0A&color=44D62C">
</p>

[English](README.md) · [Русский](README.ru.md) · [中文](README.zh-CN.md) · [فارسی](README.fa.md) · **Español** · [العربية](README.ar.md)

Una app nativa de macOS para controlar dispositivos **Yeelight** por LAN — creada para la **Yeelight Screen Light Bar Pro**
(`YLTD003`), aunque también maneja tiras RGB y bombillas normales. El software oficial solo existe para Windows; esto es un
reemplazo en SwiftUI limpio y rápido, con ambilight por sincronización de pantalla, reactividad a la música y control de grupos de varias lámparas.

> Sin nube, sin cuenta. Todo ocurre dentro de tu red LAN.

## Características

- **Control completo** — encendido, blanco frontal (brillo + temperatura de color), RGB ambiental y escenas predefinidas.
- **Control de grupo / "mezcla"** — selecciona varias lámparas y manéjalas a la vez; cada lámpara habla su propio dialecto
  del protocolo (la barra tiene un canal ambiental `bg` aparte, las tiras no).
- **Ambilight por sincronización de pantalla** — ScreenCaptureKit muestrea tu pantalla y transmite el color al canal ambiental
  de la lámpara a ~20 Hz mediante una sesión UDP.
  - **Pantalla + región por lámpara**: en una configuración multimonitor, cada lámpara puede muestrear una pantalla *distinta*
    y una región *distinta* de ella (arriba / abajo / izquierda / derecha / completa) — p. ej., la barra toma la parte superior
    de tu pantalla principal mientras una tira bajo el escritorio toma la parte inferior de otra.
  - Captura independiente de la resolución (funciona igual en 16:9, 4K, vertical y ultrawides 32:9).
  - Vista previa en vivo: un panel con forma de pantalla por cada display que muestra exactamente qué región muestrea cada lámpara, en su color real.
- **Reactividad a la música** — captura el audio del *sistema* (sin micrófono) y lo separa en graves/medios/agudos con filtros IIR.
  - El modo **Beat** impulsa el brillo con el golpe del bombo; el modo **Spectrum** mapea graves→rojo / medios→verde / agudos→azul.
- **Dos superficies** — un panel compacto en la barra de menús para ajustes rápidos y una ventana completa redimensionable (`NavigationSplitView`)
  para la configuración.
- **Robusta en una red real** — descubrimiento automático (SSDP + escaneo activo de subred), reconexión ante cambios de IP por DHCP, y
  control serializado para que la lámpara nunca pierda un comando por conexiones concurrentes.

## Requisitos

- macOS 13 (Ventura) o posterior, Apple Silicon o Intel.
- Dispositivo(s) Yeelight con **LAN Control** habilitado (app de Yeelight → dispositivo → *LAN Control*).
- Permiso de **Grabación de pantalla** (Ajustes del Sistema → Privacidad y seguridad) para los modos de sincronización de pantalla y música.

## Compilar y ejecutar

### Xcode
Abre `YeelightBar.xcodeproj` y ejecuta el esquema **YeelightBar** (⌘R). El proyecto se genera a partir de `project.yml`
con [XcodeGen](https://github.com/yonaskolb/XcodeGen); ejecuta `xcodegen generate` tras editar la especificación.

### Swift Package Manager (sin necesidad de Xcode)
```sh
swift build
./scripts/bundle.sh          # ensambla + firma build/YeelightBar.app
open build/YeelightBar.app
```
`scripts/setup-signing.sh` crea una identidad de firma de código autofirmada estable para que el permiso de Grabación de pantalla
sobreviva a las recompilaciones (una firma ad-hoc cambia en cada compilación y volvería a disparar la solicitud de permiso).

## `yeectl` — herramienta de línea de comandos

Una pequeña CLI para probar y automatizar el protocolo:

```sh
swift run yeectl discover                 # SSDP
swift run yeectl auto                      # SSDP, recurre al escaneo activo de subred
swift run yeectl state   <ip>
swift run yeectl on|off  <ip>
swift run yeectl bright  <ip> <0-100>
swift run yeectl ct      <ip> <1700-6500>
swift run yeectl rgb     <ip> <hex p. ej. FF8800>   # canal ambiental / bg
swift run yeectl rainbow <ip> [seconds]           # prueba de streaming UDP a 20 Hz
```

## Arquitectura

```
Sources/
  YeelightKit/            # librería solo de transporte, sin UI
    Yeelight.swift        # control JSON por TCP 55443 + sesión de streaming UDP 55444
    Discovery.swift       # descubrimiento por multicast SSDP
    Scan.swift            # escaneo activo de subred + validación de IP manual
  yeectl/                 # CLI
  YeelightBarApp/         # app SwiftUI
    LampController.swift   # store @MainActor: descubrimiento, control de grupos, orquestación de la sincronización
    ScreenSyncEngine.swift # captura multidisplay → color por (display, región) → reparto UDP
    MusicSyncEngine.swift  # captura del audio del sistema → beat/spectrum → reparto UDP
    FullView.swift / MenuPanelView.swift
```

El protocolo LAN de Yeelight (control por TCP, el handshake de streaming UDP, los peculiares canales `main_power`/`bg_power`
de la barra) está documentado en [`PROTOCOL.md`](PROTOCOL.md).

## Notas sobre la Screen Light Bar Pro

Esta lámpara tiene dos canales independientes — blanco frontal (`set_power` / `main_power`) y RGB ambiental
(`bg_set_power` / `bg_set_rgb`) — así que puedes usar solo el "ambiental". Su propiedad `power` no es fiable (se queda en `on`
incluso cuando el frontal está apagado); por eso la app lee `main_power` en su lugar. Las tiras normales tienen un único canal y rechazan
el `dev_toggle` exclusivo de la barra, así que el control se despacha según el tipo de dispositivo.

## Licencia

[MIT](LICENSE) — sin afiliación ni respaldo de Yeelight / Xiaomi.
