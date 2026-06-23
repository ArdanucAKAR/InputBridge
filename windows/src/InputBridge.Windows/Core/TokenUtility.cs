using System.Security.Cryptography;
using System.Text;

namespace InputBridge.Windows;

public static class TokenUtility
{
    public static string NewToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public static string Hash(string token) => Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    public static bool EqualsHash(string token, string expectedBase64)
    {
        try
        {
            var left = SHA256.HashData(Encoding.UTF8.GetBytes(token));
            var right = Convert.FromBase64String(expectedBase64);
            return CryptographicOperations.FixedTimeEquals(left, right);
        }
        catch { return false; }
    }
}
