# Yeelight Screen Light Bar Pro (YLTD003) — LAN protocol

Decoded from the official BSD-licensed
[`Yeelight/Yeelight-Chroma-Connector`](https://github.com/Yeelight/Yeelight-Chroma-Connector)
(`CUdpLight.cpp`) and the classic *Yeelight Inter-Operation Spec*. All verified
against our unit (`model: lamp15`, fw 38) on the home LAN.

## Device shape
- **Front bar** — white only, colour-temperature: `set_power` / `set_bright` / `set_ct_abx` (1700–6500 K). No RGB on this channel.
- **Back ambient** — full RGB: `bg_set_power` / `bg_set_bright` / `bg_set_rgb` / `bg_set_hsv` / `bg_set_ct_abx`.
- Also: `set_scene`, `start_cf`/`stop_cf` (colour flow), `set_segment_rgb`, `get_prop`, `cron_*`.
- "Developer / LAN Control" must be enabled in the app (it is, on our unit).

## 1. Discovery — SSDP (UDP multicast 239.255.255.250:1982)
Send:
```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1982
MAN: "ssdp:discover"
ST: wifi_bulb
```
Reply (unicast) carries `Location: yeelight://<ip>:55443`, `id`, `model`, `fw_ver`,
`support: <space-separated methods>`, plus current `power/bright/ct/rgb/...`.

## 2. Control — TCP 55443 (request/response)
One JSON object per line, CRLF-terminated:
```
{"id":1,"method":"set_ct_abx","params":[4000,"smooth",300]}\r\n
```
Reply: `{"id":1,"result":["ok"]}` or `{"id":1,"error":{...}}`.
`get_prop` → `{"id":1,"result":[<values in requested order>]}`.

⚠️ **Quota (~60 cmds/min).** Flooding makes the lamp stop replying and RST the
connection; it stays silent for up to ~1 min, then recovers. Do *not* drive
real-time effects over TCP — use the UDP session below.

⚠️ **Extended lockout (observed).** A heavy flood pushes the lamp deeper: it then
also stops answering **SSDP discovery** and **TCP control** entirely — only an
already-open **UDP session** keeps responding. Clears after a long cooldown or a
power-cycle. The real app never floods (occasional commands + UDP streaming), so
this is a stress-test artifact only.

## 3. Streaming — UDP 55444 (screen sync)
This is the low-latency path (~20 Hz verified), bypassing the TCP quota.
Two protocol versions exist; YLTD003 uses **v2** (`udp_sess_*`).

1. **Handshake** — send to `<ip>:55444`:
   ```
   {"id":N,"method":"udp_sess_new","params":[]}\r\n
   ```
   Reply: `{"id":N,"method":"udp_sess_token","params":{"token":"<32 hex>"}}`
2. **Stream colour** — for this bg-type device, every frame:
   ```
   {"id":N,"method":"bg_set_rgb","params":[<0xRRGGBB int>,"sudden",0],"token":"<token>"}\r\n
   ```
   `"sudden",0` = instant, no easing → minimal latency.
3. **Keep-alive** — every ~10 s, else the session drops after 4 misses:
   ```
   {"id":N,"method":"udp_sess_keep_alive","params":["keeplive_interval","10"],"token":"<token>"}\r\n
   ```

Device-type branch in the official code (`cDeviceType`): `0` normal → `set_scene ["color",...]`,
`1` bg device → `bg_set_rgb` (← **ours**), `2` bg device → `bg_set_scene`.
(v1 equivalents, for reference: `udp_new` / `udp_token` / `udp_keep_alive`.)

## Verified on our unit
- TCP: `get_prop`, `set_power`, `set_bright`, `set_ct_abx`, `bg_set_rgb`, `start_cf` — OK.
- UDP: token handshake + `bg_set_rgb "sudden"` streaming at **18–20 Hz, zero drops**.
