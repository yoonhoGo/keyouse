# keyouse

macOS를 **키보드만으로** 제어하는 유틸리티. 단축키로 검색 패널을 띄우면 화면의 클릭 가능한 UI 요소에 숫자 힌트가 표시되고, 숫자를 눌러 클릭·우클릭·스크롤하거나 라벨로 검색해 이동한다. Shortcat / Homerow / Vimac 류의 접근성 기반 내비게이터.

Swift + AppKit, macOS 접근성 API(`AXUIElement`) 기반. 앱 번들 없이 단일 실행 파일로 동작한다.

English: [../README.md](../README.md)

## 요구 사항

- macOS 13 이상 (Liquid Glass 패널은 macOS 26+의 `NSGlassEffectView`, 그 이하는 `NSVisualEffectView` 폴백)
- Swift 6 툴체인 (Xcode.app은 불필요, Command Line Tools면 됨)
- **손쉬운 사용(Accessibility)** 권한 필수. `⌘Tab` 창 전환을 쓰려면 **입력 모니터링(Input Monitoring)** 권한도 필요할 수 있음.

## 설치

```bash
xcode-select --install                    # Command Line Tools 없으면 먼저
brew install yoonhoGo/tap/keyouse
```

설치 시 소스에서 빌드된다(서명 불필요 — 로컬 빌드는 Gatekeeper가 막지 않고 `swift build`가 ad-hoc 서명). Homebrew가 tap 신뢰를 물으면 안내대로 진행(`brew trust --formula yoonhoGo/tap/keyouse`).

이후 **손쉬운 사용** 권한(시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용) 부여 후 `keyouse` 실행.

## 소스에서 빌드/실행

```bash
make run          # 릴리스 빌드 후 실행 (터미널은 즉시 반환됨)
make install      # /usr/local/bin/keyouse 로 설치 (sudo)
make uninstall
```

실행하면 메뉴바에 아이콘이 생기고, 터미널에서 띄워도 프로세스가 분리되어(detach) 프롬프트가 바로 돌아온다. 여러 번 실행해도 인스턴스는 하나만 유지된다. 종료는 메뉴바 › 종료 또는 `pkill -f keyouse`.

## 사용법

기본 트리거 **`⌘⇧Space`** 로 검색 패널을 연다.

| 키 | 동작 |
|----|------|
| 글자 입력 | 라벨로 요소 검색 (한글/IME 지원) |
| `숫자` | 해당 힌트 요소 좌클릭 |
| `⇧숫자` | 우클릭 |
| `⏎` / `⇧⏎` | 선택 요소 좌클릭 / 우클릭 |
| `↑` `↓` | 선택 이동 |
| `⇧↑` `⇧↓` | 스크롤 (스크롤 영역의 1/3) |
| `⌘` (누르는 동안) | 버튼류만 표시 |
| `⌃` (누르는 동안) | 입력폼(텍스트·체크박스·라디오)만 표시 |
| `⌘L` | 링크만 표시 (토글) |
| `⌃I` | 첫 입력 필드로 포커스 |
| `⌘Tab` | 창 피커 열기 · 다음 창 (`⇧⌘Tab` 이전, `⌘←→↑↓` 이동, `⌘` 떼면 선택) |
| `⌘R` | 힌트 다시 스캔 |
| `⌘,` | 환경설정 |
| `esc` | 취소 |

- 앞 앱뿐 아니라 **메뉴바·Dock** 요소도 힌트 대상.
- modifier를 누르거나 번호 입력 중에는 패널이 사라져(설정 가능) 대상을 가리지 않는다.
- 스크롤 후에는 잠시 뒤 자동으로 다시 스캔한다.
- 마우스로 다른 창을 클릭하면 패널이 닫힌다.

## 환경설정 (`⌘,`)

- **언어** (English / 한국어)
- **트리거 단축키** 녹화 변경
- **로그인 시 시작** (LaunchAgent)
- **단축키 가이드** 표시 여부 · 글자 크기
- **입력 중 패널 불투명도** (0 = 숨김)
- **스크롤 후 재스캔 딜레이**
- **`⌘` / `⌃` 필터에 표시할 요소** (AX role 체크박스)
- **기본값으로 리셋**

설정은 `UserDefaults`에 저장된다. 폰트·가이드 표시 여부는 다음에 패널을 열 때 적용된다.

## 소스에서 빌드

```bash
swift build -c release      # → .build/release/keyouse
```

구조는 `CLAUDE.md` 참고.
