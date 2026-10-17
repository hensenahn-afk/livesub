LiveSub — 일본어 영상 실시간 한국어 자막 (macOS)
==============================================

맥에서 나오는 소리를 직접 들어서 자막을 만들기 때문에 플레이어 종류와 상관없이 동작합니다.
(IINA, VLC, QuickTime, 유튜브·넷플릭스 등 브라우저, 줌 등 모두)
자막은 화면 맨 위에 떠 있고, 전체화면 영상 위에도 보이며, 클릭은 아래 플레이어로 그대로 전달됩니다.

[필요 사항]
- macOS 13(Ventura) 이상, Apple Silicon(M1~) 맥 권장
- Claude API 키 (번역용, console.anthropic.com) — 없으면 일본어 원문만 표시

[설치] — 처음 한 번만
1. 압축을 '다운로드' 폴더에 풉니다.
2. 터미널을 열고 아래 한 줄을 붙여넣은 뒤 Enter:
     bash ~/Downloads/LiveSub/설치하기.command
   (앱은 이미 빌드되어 있어 개발 도구 설치가 필요 없습니다. Python 환경과 인식 모델만 받습니다.)
3. 설치가 끝나면 메뉴 막대(화면 오른쪽 위)에 말풍선 아이콘이 생깁니다.
4. 권한 허용: 시스템 설정 > 개인정보 보호 및 보안 > '화면 및 시스템 오디오 녹음' 에서 LiveSub 켜기
   → LiveSub을 종료(메뉴 > 종료)했다가 ~/Applications/LiveSub 을 다시 엽니다.
   (화면은 녹화하지 않고 소리만 씁니다. macOS가 주기적으로 권한 확인 창을 띄울 수 있어요.)
5. 처음 열 때 API 키 입력 창이 뜹니다.

[사용]
- 일본어 영상을 재생하면 1~4초 뒤 한국어 자막이 나옵니다. 위에 작게 일본어 원문도 함께 보입니다.
- 메뉴 막대 아이콘 메뉴:
  자막 켜기/끄기 · 일본어 원문 표시 · 글자 크기 · 자막 위치 옮기기(끌어서 이동) · 위치 초기화 · API 키 설정
- 로그인 시 자동 실행: 시스템 설정 > 일반 > 로그인 항목에 LiveSub 추가

[참고]
- 음성 인식은 맥 안에서 처리되고(Whisper large-v3-turbo), 인식된 문장만 번역을 위해 Claude API로 보냅니다.
- 배경음악이 크거나 여러 사람이 동시에 말하면 정확도가 떨어질 수 있습니다.
- 번역 모델·용어집은 ~/Library/Application Support/LiveSub/config.json 에서 바꿀 수 있습니다
  (예: "claude_model": "claude-sonnet-4-5" 는 더 자연스럽지만 조금 느림 / "glossary": "人名 = 한국어 표기").
- 로그: ~/Library/Logs/LiveSub.log  (메뉴 > 로그 보기)
- 재설치/업데이트: 설치하기.command 다시 실행 (재설치 후에는 권한을 한 번 다시 허용해야 할 수 있어요)
- 삭제: ~/Applications/LiveSub.app 과 ~/Library/Application Support/LiveSub 폴더 삭제
