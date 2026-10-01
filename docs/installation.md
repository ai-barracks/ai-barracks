# 설치·업그레이드·검증

## 권장 설치: 공식 Homebrew tap

```bash
brew tap ai-barracks/ai-barracks
brew install ai-barracks/ai-barracks/ai-barracks
# 이미 같은 공식 tap으로 설치했다면:
brew update
brew upgrade ai-barracks/ai-barracks/ai-barracks

command -v aib
aib version
jq --version
```

`aib version`이 현재 사용하는 executable의 버전입니다. `brew list --versions ai-barracks`는 설치된 keg의 목록이며, 수동 설치·unlinked keg가 있으면 두 결과가 다를 수 있습니다.

기존 `cyrok90/ai-barracks` tap과 공식 `ai-barracks/ai-barracks` tap의 동명 formula는 충돌할 수 있습니다. `brew info ai-barracks`, `command -v aib`, symlink 대상과 이전 keg를 먼저 확인하세요. 사용자 설정·배럭 파일·이전 실행 파일을 백업하지 않은 채 uninstall/overwrite하지 마세요. CLI 설치는 기존 프로젝트의 `aib sync`나 provider CLI 업그레이드를 자동 수행하지 않습니다.

## 2026-10-01 후속 설치 검증

검증 환경은 macOS 27 / Homebrew 5.1.15 / CLT 26.5였습니다. Homebrew 설치에서 다음 제약을 관찰했습니다:

- `jq` 및 build dependency bottle 부재
- source build의 CLT 27 요구
- 기존 formula 제거 후 `unknown or unsupported macOS version: :dunno` 오류

이 환경의 정식 Homebrew 설치는 완료하지 못했습니다. 지원 macOS의 GitHub Homebrew install/test CI PASS를 이 환경의 성공으로 해석해서는 안 됩니다. Xcode/CLT 업그레이드, tap trust 변경, OS security 경고 우회로 해결하지 않았습니다.

### 검증된 수동 배치

[공식 v1.4.0 release](https://github.com/ai-barracks/ai-barracks/releases/tag/v1.4.0)의 tag archive를 사용했습니다:

| 항목 | 값 |
|---|---|
| Archive | `https://github.com/ai-barracks/ai-barracks/archive/refs/tags/v1.4.0.tar.gz` |
| SHA256 | `a00a51ecbfff660b14e94710d2188b8684dda9e1dfbaeaf7329c8e3bb8665c82` |
| Runtime | system `jq` 1.7.1-apple (실행 검사 PASS) |
| CLI | `~/.local/bin/aib` |
| Payload | `~/.local/share/ai-barracks/1.4.0/{templates,scripts,completions}` |
| GUI lookup shim | 기존 keg를 unlink한 뒤 user-owned `/opt/homebrew/bin/aib`에서 최신 CLI로 연결 |

이 SHA256은 **v1.4.0 archive에만** 적용됩니다. 다른 버전의 checksum으로 재사용하지 마세요.

수동 설치 시에는 다음 계약을 유지해야 합니다:

1. 공식 archive와 해당 버전 checksum을 대조하고, 기존 executable·설정·keg를 백업합니다.
2. `bin/aib`뿐 아니라 `templates`, `scripts`, `completions`를 함께 배치합니다. `TEMPLATE_DIR`은 배치된 `templates`의 절대 경로를 가리켜야 하고 sibling `scripts`가 보존되어야 합니다.
3. 새 executable의 `version`과 shell syntax를 확인한 뒤 경로를 전환합니다. 기존 user/foreign executable을 무조건 덮어쓰지 않습니다.
4. CommandCenter는 `/opt/homebrew/bin/aib`, `/usr/local/bin/aib`를 먼저 찾고, 없으면 프로세스 PATH의 `aib`를 사용합니다. GUI는 shell PATH를 그대로 물려받지 않으므로 `~/.local/bin`에 배치하는 것만으로 GUI lookup을 보장하지 않습니다.
5. 실제 CLI 버전과 CommandCenter에 표시된 CLI 버전을 모두 확인합니다. 수동 설치를 Homebrew가 관리하는 새 keg로 주장하지 않습니다.

이 shim은 **새 설치를 위한 일반적인 overwrite 명령이 아닙니다**. 이전 Homebrew keg는 unlinked 복구용으로 보존했으며, 다른 사용자의 설치 경로는 먼저 확인해야 합니다. 다음 검증을 마친 최종 상태는 CLI v1.4.0 / CC v1.5.0, model/effort runtime default, 예약 OFF였습니다.

## 모델 요청 없는 설치 검증

- 실제 실행 파일의 `aib version`: v1.4.0 PASS
- 임시 HOME·registry·provider settings에서 `aib init <fixture>`: PASS
- `aib sync --dry-run <fixture>` 전후 모든 fixture 파일의 hash 동일: PASS
- `aib hooks codex install <fixture>`의 hook definitions 생성: PASS; project trust·global provider 설정·`.codex/config.toml` 변경 없음
- CC 재실행 후 CLI v1.4.0 표시: PASS

`--dry-run`은 문서상 순서대로 **path 앞에** 둡니다. 검증 fixture만 초기화했으며 기존 등록 배럭·provider 설정은 변경하지 않았습니다. 실제 모델 요청, 실제 예약 slot 전송과 모델 품질 eval은 수행하지 않았습니다.

## 복구·기존 프로젝트

수동 CLI 및 GUI shim을 설치할 때는 이전 경로를 기록하세요. 이전 Homebrew CLI로 돌아가려면 먼저 본인이 만든 수동 shim임을 확인하고 별도 보존/이동한 뒤 이전 keg를 `brew link ai-barracks`로 다시 연결합니다. 임시 디렉터리의 백업은 영구 보존이 아니므로 장기 rollback이 필요하면 별도 안전한 경로로 옮겨야 합니다.

CLI 설치 완료와 프로젝트 템플릿 동기화는 다릅니다. 기존 배럭은 변경하지 않았습니다. 필요하면 먼저 `aib sync --dry-run /path/to/barrack`으로 차이를 검토하고, 프로젝트 변경을 백업한 다음 별도로 동기화하세요.
