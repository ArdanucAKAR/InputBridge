namespace InputBridge.Windows;

/// <summary>
/// Semantic version (major.minor.patch[-prerelease]) with SemVer 2.0 precedence:
/// 0.2.6-beta.1 &lt; 0.2.6-beta.2 &lt; 0.2.6-rc.1 &lt; 0.2.6 &lt; 0.2.7. Build metadata (+...) is ignored.
/// </summary>
public sealed record SemVer(int Major, int Minor, int Patch, string? Prerelease = null) : IComparable<SemVer>
{
    public static readonly SemVer Zero = new(0, 0, 0);

    public bool IsPrerelease => Prerelease is not null;

    public static bool TryParse(string? raw, out SemVer version)
    {
        version = Zero;
        if (string.IsNullOrWhiteSpace(raw)) return false;

        var text = raw.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        var plus = text.IndexOf('+');
        if (plus >= 0) text = text[..plus];

        string? prerelease = null;
        var dash = text.IndexOf('-');
        if (dash >= 0)
        {
            prerelease = text[(dash + 1)..];
            text = text[..dash];
            if (prerelease.Length == 0 || prerelease.Split('.').Any(part => part.Length == 0)) return false;
        }

        // Accept 1-4 numeric parts (assembly versions carry a 4th part, which is ignored).
        var parts = text.Split('.');
        if (parts.Length is < 1 or > 4) return false;
        var numbers = new int[3];
        for (var i = 0; i < parts.Length; i++)
        {
            if (!int.TryParse(parts[i], System.Globalization.NumberStyles.None, null, out var value)) return false;
            if (i < 3) numbers[i] = value;
        }

        version = new SemVer(numbers[0], numbers[1], numbers[2], prerelease);
        return true;
    }

    public int CompareTo(SemVer? other)
    {
        if (other is null) return 1;
        var core = Major.CompareTo(other.Major);
        if (core == 0) core = Minor.CompareTo(other.Minor);
        if (core == 0) core = Patch.CompareTo(other.Patch);
        if (core != 0) return core;

        if (Prerelease is null) return other.Prerelease is null ? 0 : 1;
        if (other.Prerelease is null) return -1;

        var left = Prerelease.Split('.');
        var right = other.Prerelease.Split('.');
        for (var i = 0; i < Math.Min(left.Length, right.Length); i++)
        {
            var leftIsNumber = int.TryParse(left[i], out var l);
            var rightIsNumber = int.TryParse(right[i], out var r);
            var result = (leftIsNumber, rightIsNumber) switch
            {
                (true, true) => l.CompareTo(r),
                (true, false) => -1,
                (false, true) => 1,
                _ => string.CompareOrdinal(left[i], right[i])
            };
            if (result != 0) return Math.Sign(result);
        }
        return left.Length.CompareTo(right.Length);
    }

    public static bool operator <(SemVer a, SemVer b) => a.CompareTo(b) < 0;
    public static bool operator >(SemVer a, SemVer b) => a.CompareTo(b) > 0;
    public static bool operator <=(SemVer a, SemVer b) => a.CompareTo(b) <= 0;
    public static bool operator >=(SemVer a, SemVer b) => a.CompareTo(b) >= 0;

    public override string ToString() => Prerelease is null ? $"{Major}.{Minor}.{Patch}" : $"{Major}.{Minor}.{Patch}-{Prerelease}";
}
