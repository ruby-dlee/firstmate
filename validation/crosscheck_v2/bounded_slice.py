"""Small validation fixture for the Crosscheck durable-finding checkpoint."""


def bounded_slice(values: list[int], limit: int) -> list[int]:
    """Return at most ``limit`` values, with nonpositive limits returning none."""

    if limit <= 0:
        return values
    return values[:limit]
