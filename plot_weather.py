import sys
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd


SCRIPT_DIR = Path(__file__).resolve().parent
CSV_PATH = SCRIPT_DIR / "weather.csv"
PLOT_PATH = SCRIPT_DIR / "temperature.png"
REQUIRED_COLUMNS = {"datetime", "temperature_C"}


def load_weather(csv_path: Path) -> pd.DataFrame:
    """CSV를 읽고 datetime과 기온을 변환한 뒤 시간순으로 정렬한다."""
    weather = pd.read_csv(csv_path, encoding="utf-8-sig")
    missing_columns = REQUIRED_COLUMNS - set(weather.columns)
    if missing_columns:
        raise ValueError(f"CSV에 필요한 열이 없습니다: {', '.join(sorted(missing_columns))}")

    weather["datetime"] = pd.to_datetime(weather["datetime"], errors="raise")
    temperature = pd.to_numeric(weather["temperature_C"], errors="coerce")
    invalid_temperature = weather["temperature_C"].notna() & temperature.isna()
    if invalid_temperature.any():
        raise ValueError("temperature_C 열에 숫자로 변환할 수 없는 값이 있습니다.")
    weather["temperature_C"] = temperature

    if weather["datetime"].duplicated().any():
        raise ValueError("CSV에 중복 datetime이 있습니다.")
    return weather.sort_values("datetime").set_index("datetime")


def make_hourly_series(weather: pd.DataFrame) -> tuple[pd.DataFrame, pd.DatetimeIndex]:
    """첫 시각부터 마지막 시각까지 1시간 간격을 채우고 누락 시각을 돌려준다."""
    if weather.empty:
        raise ValueError("CSV에 그래프로 그릴 데이터가 없습니다.")

    hourly_index = pd.date_range(
        start=weather.index.min(),
        end=weather.index.max(),
        freq="h",
    )
    missing_times = hourly_index.difference(weather.index)
    return weather.reindex(hourly_index), missing_times


def save_and_show_plot(weather: pd.DataFrame, output_path: Path) -> None:
    """결측 기온 구간은 연결하지 않는 시간-기온 선 그래프를 저장하고 표시한다."""
    figure, axis = plt.subplots(figsize=(12, 6))
    axis.plot(weather.index, weather["temperature_C"], marker=".")
    axis.set_title("Temperature over time")
    axis.set_xlabel("Time (KST)")
    axis.set_ylabel("Temperature (°C)")
    figure.tight_layout()
    figure.savefig(output_path, dpi=150)
    plt.show()


def main() -> int:
    """로컬 CSV만 사용해 시간 간격을 확인하고 그래프 파일을 만든다."""
    try:
        weather = load_weather(CSV_PATH)
        hourly_weather, missing_times = make_hourly_series(weather)
        save_and_show_plot(hourly_weather, PLOT_PATH)
    except (OSError, ValueError, pd.errors.ParserError) as error:
        print(f"그래프 생성 실패: {error}", file=sys.stderr)
        return 1

    print(f"시간 간격 누락 수: {len(missing_times)}")
    if len(missing_times):
        print("누락 시각:")
        for timestamp in missing_times:
            print(timestamp.strftime("%Y-%m-%d %H:%M"))
    print(f"그래프 저장 위치: {PLOT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
