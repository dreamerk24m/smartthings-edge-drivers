# SmartThings Edge Drivers

Local SmartThings Edge drivers, no manufacturer cloud needed. · [한국어](#한국어)

**Install:** [Join the channel](https://bestow-regional.api.smartthings.com/invite/Kr2zpk4VArjA) → install the driver to your hub → SmartThings app **+ → Add device → Scan for nearby devices**.

## Yeelight LAN

| Model    | Device        | In SmartThings                                          |
| -------- | ------------- | ------------------------------------------------------- |
| `lamp15` | Light Bar     | Front Light + Back Light                                |
| `ceilb`  | Ceiling light | Main Light + Moonlight, Background as a separate device |

> [!IMPORTANT]
> Turn on **LAN Control** in the Yeelight app first.

- Instant updates from the remote and the Yeelight app; reconnects and finds a new IP by itself.
- Circadian Lighting and Fade supported.
- Like Matter lights: changing color while off only saves it and does not turn the light on; changing brightness turns it on.
- Moonlight: the main switch is the power, the Moonlight switch is the mode. Circadian Lighting does not set off the moonlight.
- Front/back link can only be changed in the Yeelight app.
- Color temperature: 2700–6500 K (ceiling Background: 1700–6500 K).

Personal project, provided as is.

---

## 한국어

제조사 클라우드 없이 사용하는 스마트싱스 Edge 드라이버입니다.

**설치:** [채널 가입](https://bestow-regional.api.smartthings.com/invite/Kr2zpk4VArjA) → 허브에 드라이버 설치 → 스마트싱스 앱 **+ → 기기 추가 → 주변 기기 검색**.

### Yeelight LAN

| 모델     | 기기      | 스마트싱스에서                  |
| -------- | --------- | ------------------------------- |
| `lamp15` | Light Bar | 앞 조명 + 뒤 조명               |
| `ceilb`  | 천장등    | 본등 + 달빛, 배경등은 별도 기기 |

> [!IMPORTANT]
> Yeelight 앱에서 **LAN 제어**를 먼저 켜 주십시오.

- 리모컨이나 Yeelight 앱으로 바꿔도 바로 반영되며, 연결이 끊기거나 IP가 바뀌어도 스스로 다시 찾습니다.
- 하루 조명과 페이드를 지원합니다.
- Matter 조명처럼 꺼진 상태에서 색을 바꾸면 저장만 하고 켜지지 않습니다. 밝기를 바꾸면 켜집니다.
- 달빛: 본등 스위치는 전원, 달빛 스위치는 모드입니다. 하루 조명이 달빛을 해제하지 않습니다.
- 앞뒤 연동은 Yeelight 앱에서만 바꿀 수 있습니다.
- 색온도: 2700–6500 K (천장등 배경등: 1700–6500 K)

개인 프로젝트이며, 동작을 보증하지 않습니다.
