# CLAUDE.md — keyouse

키보드로 macOS UI를 제어하는 접근성 기반 유틸리티. **Swift + AppKit, SPM 단일 실행 파일**(앱 번들 없음). 사용자 문서는 `README.md`.

> 참고: 저장소 폴더명은 `shott`이지만 프로그램/타깃명은 `keyouse`다.

## 빌드 · 실행 · 검증

```bash
swift build -c release        # 또는 make build
make run                      # 빌드 후 실행 (detach되어 즉시 반환)
make install / uninstall      # /usr/local/bin/keyouse (sudo)
```

- GUI + 전역 단축키/이벤트 탭이라 **상호작용(키 입력)은 헤드리스로 검증 불가**. 코드 변경 후엔 `swift build -c release`로 컴파일을 확인하고, 실제 동작(패널·클릭·스크롤·⌘Tab)은 사용자가 `make run`으로 확인하는 흐름.
- 구동 여부만 볼 때: 실행 후 `pgrep -fl release/keyouse` 확인. 테스트 전 `pkill -9 -f keyouse; rm -f "${TMPDIR}keyouse.lock"`로 이전 인스턴스/락 정리(단일 인스턴스라 잔여가 있으면 새 실행이 즉시 종료됨).

## 구조 (Sources/keyouse/)

| 파일 | 책임 |
|------|------|
| `AX.swift` | 접근성 스캔/액션. `Hit`(요소+pid+role+subrole+frame), `WindowInfo`. `scan`(앞 앱+메뉴바+Dock), `scanWindow`, `windows`(열린 창 열거), `press`/`rightClick`/`scroll`/`focus`/`raise`. `actionableRoles`(수집 대상 role), `chromeSubroles`(신호등 등 항상 제외) |
| `Overlay.swift` | `OverlayWindow`(전역 투명·키 가능), `HighlightView`(요소 하이라이트 + 숫자 뱃지, 입력 중 프리픽스 흐림) |
| `Panel.swift` | `PanelView`(글래스 검색 필드 + 개수 + 기능별 그룹 가이드 그리드), `Panel.makeGlass`(macOS 26+ `NSGlassEffectView`, 이하 `NSVisualEffectView` 폴백), `Panel.size` |
| `Picker.swift` | `WindowPickerView`(⌘Tab 창 목록) |
| `Settings.swift` | `Settings`(UserDefaults 접근자 + `reset`), `LoginItem`(LaunchAgent plist), `SettingsWindow`(프로그래매틱 설정 창) |
| `main.swift` | `AppController`(전체 오케스트레이션) + 진입점(detach·단일 인스턴스·상태바) |

## 핵심 규약 / 주의점

- **Swift 6 strict concurrency**. `AppController`/`SettingsWindow`는 `@MainActor`. `NSEvent` 전역/로컬 모니터와 `CGEventTap` C 콜백은 nonisolated에서 실행되므로, 콜백 안에서 **Sendable 값(keyCode·Bool·문자열)만 추출**해 `MainActor.assumeIsolated { ... }`로 넘긴다. `NSEvent`/`NSRunningApplication` 등 비-Sendable 객체를 클로저 경계로 넘기지 말 것.
- **좌표 변환**: AX/CG는 좌상단 원점, Cocoa는 좌하단 원점. 하이라이트는 `screenHeight - y`로 변환하며 **주 디스플레이 기준만** 지원(멀티모니터 미구현). 클릭/스크롤용 CG 좌표는 AX와 같은 좌상단 원점이라 변환 불필요.
- **클릭**: `AXPress` 우선, 실패 시 `CGEvent` 합성 클릭. **우클릭/스크롤**은 AX 액션이 없어 `CGEvent`. 스크롤은 Vimac 방식 — 가장 큰 `AXScrollArea`를 찾아 커서를 그 중앙으로 워프 후 휠 이벤트(`.cghidEventTap`)를 쏜다.
- **키 라우팅**: 패널은 키 윈도우이고 검색 텍스트는 `NSTextField`(first responder)가 IME로 처리. 로컬 `keyDown` 모니터가 제어키/숫자만 소비(consume)하고 문자는 필드로 흘려보낸다(`handleKeyDown`이 소비 여부 Bool 반환). `⌘Tab`은 시스템 스위처가 먼저 가로채므로 **`CGEventTap`(패널 열린 동안만)** 으로 가로챈다.
- **필터**: `⌘`→`Settings.cmdVisibleRoles`, `⌃`→`Settings.ctrlVisibleRoles`(누르는 동안 순간 적용), `⌘L`→링크 sticky 토글. modifier flagsChanged로 상태 갱신.
- **패널 가시성**: modifier 눌림 또는 번호 입력 중이면 `Settings.panelActiveOpacity`대로 처리(0이면 `isHidden`으로 완전 제거).
- **진입점**: `KEYOUSE_DETACHED` 미설정 시 자기 자신을 자식으로 재실행하고 부모는 `exit(0)`(터미널 반환). 자식은 `setsid()` 후 `${TMPDIR}keyouse.lock` `flock`으로 단일 인스턴스 보장.
- **권한**: 접근성 필수. `CGEventTap` 생성 실패 시 콘솔에 안내만 출력하고 계속 진행(⌘Tab만 비활성).

## 코드 스타일

- 리팩터링/기능 추가 시 주변 코드 톤 유지. 의도적 단순화엔 `ponytail:` 주석으로 이유/상한을 남긴다(기존 예시 참고).
- 새 단축키/설정 추가 시: 키 처리(`handleKeyDown`/tap) + 상태 초기화(`dismiss`) + 가이드 문구(`PanelView.groups`) + 필요 시 `Settings`/설정 창을 함께 갱신.
