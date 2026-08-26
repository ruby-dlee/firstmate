"""Executable regression for the deliberate validation defect."""

from bounded_slice import bounded_slice


def test_nonpositive_limit_returns_no_values() -> None:
    assert bounded_slice([1, 2, 3], 0) == []


if __name__ == "__main__":
    test_nonpositive_limit_returns_no_values()
