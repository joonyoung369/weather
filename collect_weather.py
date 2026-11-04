import csv
import getpass
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, quote_plus

import requests


API_URL = "https://apihub.kma.go.kr/api/typ01/url/kma_sfctm3.php"
TIMEOUT_SECONDS = 30
OUTPUT_DIR = Path(__file__).resolve().parent
RAW_RESPONSE_PATH = OUTPUT_DIR / "weather_raw.txt"
CSV_PATH = OUTPUT_DIR / "weather.csv"

# 공식 출력 필드는 1부터 세는 위치로 확인한다.
FIELD_POSITIONS = {
    "TM": 1,
    "WS": 4,
    "TA": 12,
    "HM": 14,
}
CSV_COLUMNS = [
    "datetime",
    "temperature_C",
    "humidity_pct",
    "wind_speed_ms",
]
MISSING_VALUES = {"", "-99", "-99.0", "-99.9", "-999", "-999.0", "-9999"}


def decode_response(response: requests.Response) -> str:
    """응답의 charset을 우선 사용해 본문을 문자열로 변환한다."""
    encoding = response.encoding or response.apparent_encoding or "utf-8"
    return response.content.decode(encoding)


def redact_secrets(text: str, auth_key: str, request_url: str) -> str:
    """오류 안내문에서 인증키와 인증키가 들어간 요청 주소를 제거한다."""
    secrets = (request_url, quote(auth_key, safe=""), quote_plus(auth_key), auth_key)
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[REDACTED]")
    return text


def response_message(body: str, auth_key: str, request_url: str) -> str:
    """오류 본문에 JSON message가 있으면 우선하고, 없으면 본문을 안내한다."""
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        payload = None

    if isinstance(payload, dict) and payload.get("message"):
        message = str(payload["message"])
    else:
        message = body.strip() or "응답 본문에 오류 설명이 없습니다."
    return redact_secrets(message, auth_key, request_url)


def api_message(body: str) -> str:
    """HTTP 200 본문에 JSON 오류 message가 포함된 경우를 찾는다."""
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return ""
    if isinstance(payload, dict) and payload.get("message"):
        return str(payload["message"])
    return ""


def plain_api_message(body: str) -> str:
    """평문 오류 응답을 찾되, 관측시각으로 시작하는 자료 행은 오류로 보지 않는다."""
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not stripped.split()[0].isdigit():
            return stripped
        break
    return ""


def save_raw_response(response: requests.Response) -> None:
    """분석에 사용한 원본 응답 바이트를 변형 없이 보관한다."""
    RAW_RESPONSE_PATH.write_bytes(response.content)


def find_and_check_header(lines: list[str]) -> list[str]:
    """번호가 붙은 설명 주석에서 TM/WS/TA/HM의 공식 위치를 검증한다."""
    documented_positions: dict[str, int] = {}
    for line in lines:
        if not line.lstrip().startswith("#"):
            continue
        match = re.match(r"\s*#\s*(\d+)\.\s*([A-Z][A-Z0-9_]*)\s*:", line)
        if match:
            position, field = match.groups()
            if field in FIELD_POSITIONS:
                documented_positions[field] = int(position)

    if all(documented_positions.get(field) == position
           for field, position in FIELD_POSITIONS.items()):
        return []

    # 일부 응답 형식은 번호 없는 단일 필드 헤더를 제공하므로 함께 지원한다.
    expected = {name: position - 1 for name, position in FIELD_POSITIONS.items()}
    for line in lines:
        if not line.lstrip().startswith("#"):
            continue
        fields = line.lstrip()[1:].split()
        if all(index < len(fields) and fields[index] == name
               for name, index in expected.items()):
            return fields
    expected_text = ", ".join(
        f"{name}({position})" for name, position in FIELD_POSITIONS.items()
    )
    raise ValueError(f"필드 헤더에서 공식 위치를 확인하지 못했습니다: {expected_text}")


def parse_value(raw_value: str, field: str) -> float | str:
    """결측 표기만 빈 값으로 바꾸고, 음수 기온은 유효한 수치로 보존한다."""
    if raw_value in MISSING_VALUES:
        return ""
    try:
        value = float(raw_value)
    except ValueError as error:
        raise ValueError(f"{field} 필드 값이 숫자가 아닙니다.") from error
    if not math.isfinite(value):
        return ""
    if field != "TA" and value < 0:
        return ""
    if field == "TA" and value <= -90:
        return ""
    return value


def parse_observations(body: str) -> list[dict[str, str | float]]:
    """주석을 제외하고 공백 분리한 실제 자료 행을 표준 열로 변환한다."""
    lines = body.splitlines()
    find_and_check_header(lines)
    rows: list[dict[str, str | float]] = []
    required_index = max(FIELD_POSITIONS.values()) - 1

    for line_number, line in enumerate(lines, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        values = line.split()
        if len(values) <= required_index:
            raise ValueError(f"{line_number}번째 줄에 필요한 필드가 부족합니다.")
        try:
            observation_time = datetime.strptime(values[0], "%Y%m%d%H%M")
        except ValueError as error:
            raise ValueError(f"{line_number}번째 줄의 TM 형식이 올바르지 않습니다.") from error

        rows.append(
            {
                "datetime": observation_time.strftime("%Y-%m-%d %H:%M"),
                "temperature_C": parse_value(values[FIELD_POSITIONS["TA"] - 1], "TA"),
                "humidity_pct": parse_value(values[FIELD_POSITIONS["HM"] - 1], "HM"),
                "wind_speed_ms": parse_value(values[FIELD_POSITIONS["WS"] - 1], "WS"),
            }
        )

    if not rows:
        raise ValueError("응답에 실제 자료 행이 없습니다.")
    return rows


def sort_and_check_duplicates(
    rows: list[dict[str, str | float]],
) -> tuple[list[dict[str, str | float]], int]:
    """시각순으로 정렬하고 중복 시각은 값이 같은 경우에만 하나로 정리한다."""
    sorted_rows = sorted(rows, key=lambda row: str(row["datetime"]))
    unique_rows: list[dict[str, str | float]] = []
    by_time: dict[str, dict[str, str | float]] = {}
    duplicate_count = 0

    for row in sorted_rows:
        timestamp = str(row["datetime"])
        previous = by_time.get(timestamp)
        if previous is None:
            by_time[timestamp] = row
            unique_rows.append(row)
        else:
            duplicate_count += 1
            if any(previous[column] != row[column] for column in CSV_COLUMNS[1:]):
                raise ValueError(f"{timestamp} 중복 행의 관측값이 서로 다릅니다.")
    return unique_rows, duplicate_count


def save_csv(rows: list[dict[str, str | float]]) -> None:
    """행 인덱스 없이 지정된 열 순서와 UTF-8 BOM 인코딩으로 CSV를 저장한다."""
    with CSV_PATH.open("w", encoding="utf-8-sig", newline="") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    auth_key = getpass.getpass("기상청 API 인증키: ")
    params = {
        "tm1": "202510010000",
        "tm2": "202510072300",
        "stn": "108",
        "help": "1",
        "authKey": auth_key,
    }

    try:
        response = requests.get(API_URL, params=params, timeout=TIMEOUT_SECONDS)
    except requests.exceptions.RequestException as error:
        print(
            f"요청 실패 ({type(error).__name__}). 요청 주소와 인증키는 출력하지 않았습니다.",
            file=sys.stderr,
        )
        return 1

    print(f"HTTP 상태: {response.status_code}")
    try:
        save_raw_response(response)
        body = decode_response(response)
    except (OSError, LookupError, UnicodeError) as error:
        print(f"응답 저장 또는 문자 해석 실패: {type(error).__name__}", file=sys.stderr)
        return 1

    request_url = response.request.url if response.request else ""
    if not response.ok:
        print(
            f"오류 message: {response_message(body, auth_key, request_url)}",
            file=sys.stderr,
        )
        return 1
    message = api_message(body)
    if message:
        print(
            f"오류 message: {redact_secrets(message, auth_key, request_url)}",
            file=sys.stderr,
        )
        return 1
    message = plain_api_message(body)
    if message:
        print(
            f"오류 message: {redact_secrets(message, auth_key, request_url)}",
            file=sys.stderr,
        )
        return 1

    lines = body.splitlines()
    print("\n본문 앞 15줄:")
    for line in lines[:15]:
        print(redact_secrets(line, auth_key, request_url))

    try:
        rows = parse_observations(body)
        rows, duplicate_count = sort_and_check_duplicates(rows)
        save_csv(rows)
    except (OSError, ValueError) as error:
        print(f"응답 처리 실패: {error}", file=sys.stderr)
        return 1

    print(
        "\n헤더 위치 확인: "
        + ", ".join(f"{name}={position}" for name, position in FIELD_POSITIONS.items())
    )
    print("\n실제 데이터 행 최대 3개:")
    data_lines = [
        line for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    ]
    for line in data_lines[:3]:
        print(redact_secrets(line, auth_key, request_url))
    print(f"\n중복 시각 행 제거: {duplicate_count}")
    print(f"행 수: {len(rows)}")
    for column in CSV_COLUMNS:
        missing_count = sum(row[column] == "" for row in rows)
        print(f"{column} 결측 수: {missing_count}")
    print(f"첫 시각: {rows[0]['datetime']}")
    print(f"마지막 시각: {rows[-1]['datetime']}")
    print(f"원본 응답 저장 위치: {RAW_RESPONSE_PATH}")
    print(f"CSV 저장 위치: {CSV_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
