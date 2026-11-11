# 기상청 시간자료 수집 및 시각화

기상청 API 허브의 지상 관측 시간자료를 받아 CSV로 저장하고, 저장된 기온 자료를 시간 그래프로 표시하는 Python 프로젝트입니다.

## 구성

| 파일 | 설명 |
| --- | --- |
| `collect_weather.py` | 지정한 지점과 기간의 기상청 API 응답을 받아 CSV와 원본 응답을 저장합니다. |
| `plot_weather.py` | 로컬 `weather.csv`를 읽어 시간-기온 그래프를 저장하고 화면에 표시합니다. API를 호출하지 않습니다. |
| `weather.csv` | 처리된 관측 자료입니다. |
| `weather_raw.txt` | 수집 당시 API에서 받은 원본 응답입니다. |
| `temperature.png` | `plot_weather.py`가 생성한 그래프 이미지입니다. |

## 요구 사항

- Python 3.10 이상
- `requests`
- `pandas`
- `matplotlib`

PowerShell에서 패키지를 설치합니다.

```powershell
python -m pip install requests pandas matplotlib
```

## 관측 자료 수집

```powershell
python .\collect_weather.py
```

실행 중 기상청 API 인증키를 입력합니다. 입력 내용은 터미널에 표시되지 않습니다. 현재 요청 설정은 다음과 같습니다.

- 관측소: 108
- 시작 시각: `2025-10-01 00:00` (KST)
- 종료 시각: `2025-10-07 23:00` (KST)
- API: [기상청 지상 시간자료 기간 조회](https://apihub.kma.go.kr/api/typ01/url/kma_sfctm3.php)

요청에는 timeout이 설정되어 있으며, 인증키나 인증키가 포함된 요청 주소는 오류 출력에 노출하지 않습니다. 성공하면 원본 응답을 `weather_raw.txt`에 저장하고, 아래 열 순서로 `weather.csv`를 생성합니다.

```text
datetime, temperature_C, humidity_pct, wind_speed_ms
```

CSV는 `utf-8-sig` 인코딩이며 행 인덱스는 포함하지 않습니다. 자료 시각은 오름차순으로 정렬하고, 동일한 시각에 값이 다른 행이 있으면 저장을 중단합니다. 결측값은 빈 칸으로 저장됩니다.

## 그래프 생성

같은 폴더에 `weather.csv`가 있는 상태에서 실행합니다.

```powershell
python .\plot_weather.py
```

스크립트는 CSV의 `datetime`을 시간 형식으로 변환하고 정렬한 뒤, 첫 시각부터 마지막 시각까지 1시간 간격의 누락 시각을 확인합니다. 없는 시각은 빈 행으로 채우며, 기온 결측 구간은 선으로 연결하지 않습니다. 그래프는 `temperature.png`에 저장되고 화면에도 표시됩니다. 확인된 누락 시각과 이미지 저장 경로도 터미널에 출력됩니다.

그래프 제목과 축 이름은 다음과 같습니다.

- 제목: `Temperature over time`
- 가로축: `Time (KST)`
- 세로축: `Temperature (°C)`

## 풍속 학습 데이터 생성

`asos_108_2023_2024.csv`에서 관측 누락 시각을 시간축에 반영하고, 풍속 예측용 입력과 정답을 생성합니다. 원본은 변경하지 않습니다.

```powershell
.\make_wind_dataset.ps1
```

`wind_dataset.csv`의 `prediction_time`은 입력을 기준으로 예측하는 시각이며 `target_time`은 정답 시각입니다. 입력 열은 해당 시각의 풍속·기온·습도와 1시간 및 2시간 전 풍속이고, `target_wind_speed_ms`는 1시간 뒤 실제 풍속입니다. 필요한 입력이나 정답 중 하나라도 없으면 해당 행을 저장하지 않습니다.

## 풍속 선형 회귀 학습 및 평가

KST 기준 `target_time`이 2023년 1월부터 2024년 11월까지인 행으로 선형 회귀를 한 번 학습하고, 2024년 12월 행만 평가합니다. 평가 기간에는 재학습하지 않습니다. 현재 풍속을 유지하는 기준 예측과, 현재 풍속·1·2시간 전 풍속·기온·습도를 사용하는 선형 회귀를 같은 평가 행에서 비교합니다. 음수 회귀 예측은 0으로 자릅니다.

```powershell
.\train_wind_model.ps1
```

두 방법의 평가 예측은 `predictions.csv`에 저장됩니다.

## 풍속 예측 주간 그래프

`predictions.csv`에서 정답 시각 기준 2024년 12월 1일 00시부터 12월 7일 23시까지 세 예측 방법을 비교하는 그래프를 저장합니다. MAE는 해당 주가 아닌 12월 전체 평가 행으로 계산합니다.

```powershell
.\plot_wind_predictions.ps1
```

그래프 파일은 `prediction_week.png`입니다.

## 주요 함수

### `collect_weather.py`

- `decode_response`: 응답의 charset을 사용해 본문을 디코딩합니다.
- `find_and_check_header`: API 응답의 주석을 확인해 필드 번호와 이름이 예상한 위치에 있는지 검증합니다.
- `parse_observations`: 실제 자료 행을 공백으로 분리하고 필요한 관측값을 CSV 열 구조로 변환합니다.
- `sort_and_check_duplicates`: 시각순으로 정렬하고 값이 같은 중복 행을 정리합니다. 같은 시각의 값이 다르면 오류를 냅니다.
- `save_csv`: 지정된 열 순서와 인코딩으로 CSV를 저장합니다.
- `main`: 인증키 입력, API 요청, 원본 응답 보관, 자료 처리와 결과 출력을 수행합니다.

### `plot_weather.py`

- `load_weather`: CSV를 읽고 시각과 기온을 변환한 다음 시각순으로 정렬합니다.
- `make_hourly_series`: 1시간 간격의 시간축을 만들고 누락 시각을 반환합니다.
- `save_and_show_plot`: 그래프를 PNG 파일로 저장하고 화면에 표시합니다.
- `main`: 로컬 CSV 처리, 누락 시각 출력 및 그래프 생성을 실행합니다.
