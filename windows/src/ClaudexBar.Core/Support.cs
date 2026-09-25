using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ClaudexBar.Core;

public static class TimeParsing
{
    public static DateTimeOffset? Iso8601(string? s)
    {
        if (string.IsNullOrWhiteSpace(s) || s.Length < 19 || s[4] != '-' || s[7] != '-') return null;
        return DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
    }

    /// <summary>Epoch in seconds, milliseconds, microseconds or nanoseconds.</summary>
    public static DateTimeOffset? Epoch(double v)
    {
        if (!double.IsFinite(v) || v <= 0) return null;
        double seconds = v > 1e17 ? v / 1e9 : v > 1e14 ? v / 1e6 : v > 1e11 ? v / 1e3 : v;
        try { return DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(seconds * 1000)); }
        catch (ArgumentOutOfRangeException) { return null; }
    }

    /// <summary>A number (epoch), a numeric string, or an ISO-8601 string.</summary>
    public static DateTimeOffset? Flexible(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return Epoch(d);
        if (v.TryGetValue<long>(out var l)) return Epoch(l);
        if (v.TryGetValue<string>(out var s))
            return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? Epoch(n) : Iso8601(s);
        return null;
    }

    private static readonly string[] Months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

    /// <summary>`ps -o lstart` style (UTC): "Tue Sep 22 19:21:32 2026" / "Wed Sep  2 08:00:00 2026".</summary>
    public static DateTimeOffset? ProcStart(string? s)
    {
        if (s is null) return null;
        var parts = s.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 5 || parts[1].Length < 3) return null;
        int month = Array.IndexOf(Months, parts[1][..3].ToLowerInvariant()) + 1;
        var hms = parts[3].Split(':');
        if (month == 0 || hms.Length != 3 || !int.TryParse(parts[2], out var day) || !int.TryParse(parts[4], out var year)
            || !int.TryParse(hms[0], out var h) || !int.TryParse(hms[1], out var m) || !int.TryParse(hms[2], out var sec))
            return null;
        try { return new DateTimeOffset(year, month, day, h, m, sec, TimeSpan.Zero); }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}

public static class Durations
{
    public static string Short(TimeSpan interval)
    {
        long s = Math.Max(0, (long)interval.TotalSeconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m";
        if (s < 86_400) return $"{s / 3600}h";
        return $"{s / 86_400}d";
    }
}

public static partial class TextSanitizer
{
    /// <summary>One line, no control characters or ANSI escapes, secrets redacted, truncated.</summary>
    public static string OneLine(string? input, int maxLength = 100)
    {
        if (string.IsNullOrEmpty(input)) return "";
        var sb = new StringBuilder(Math.Min(input.Length, maxLength * 2));
        bool lastSpace = false;
        int budget = maxLength * 4 + 256;
        for (int i = 0; i < input.Length && budget > 0; i++, budget--)
        {
            char c = input[i];
            if (c == '\u001B')
            {
                if (i + 1 < input.Length && input[i + 1] == '[')
                {
                    i += 2;
                    while (i < input.Length && !(input[i] >= '@' && input[i] <= '~')) i++;
                }
                continue;
            }
            if (char.IsControl(c) || char.IsWhiteSpace(c))
            {
                if (!lastSpace && sb.Length > 0) sb.Append(' ');
                lastSpace = true;
                continue;
            }
            sb.Append(c);
            lastSpace = false;
        }
        var text = Redact(sb.ToString().TrimEnd());
        if (text.Length > maxLength) text = text[..Math.Max(1, maxLength - 1)] + "…";
        return text;
    }

    [GeneratedRegex(@"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}")] private static partial Regex Bearer();
    [GeneratedRegex(@"sk-ant-[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")]
    private static partial Regex Tokens();
    [GeneratedRegex(@"(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd)[A-Za-z0-9_]*\s*[=:]\s*)[^\s‹]+")]
    private static partial Regex KeyValue();
    [GeneratedRegex(@"(?i)(--(?:password|token|api-key)(?:=|\s+))[^\s‹]+")] private static partial Regex Flag();

    public static string Redact(string input)
    {
        if (input.Length < 8) return input;
        var t = Bearer().Replace(input, "Bearer ‹redacted›");
        t = Tokens().Replace(t, "‹redacted›");
        t = KeyValue().Replace(t, m => m.Groups[1].Value + "‹redacted›");
        t = Flag().Replace(t, m => m.Groups[1].Value + "‹redacted›");
        return t;
    }
}

/// <summary>A credential that never appears in ToString / debugger output.</summary>
public sealed class SecretToken(string value)
{
    private readonly string _value = value;
    public bool IsEmpty => _value.Length == 0;
    public T WithValue<T>(Func<string, T> body) => body(_value);
    public int Fingerprint => StringComparer.Ordinal.GetHashCode(_value);
    public override string ToString() => $"<redacted {_value.Length} chars>";
    public override bool Equals(object? obj) => obj is SecretToken o && o._value == _value;
    public override int GetHashCode() => Fingerprint;
}

/// <summary>Lenient JSON access helpers: wrong types yield null instead of throwing.</summary>
public static class Json
{
    public static JsonNode? Parse(ReadOnlySpan<byte> utf8)
    {
        try { return JsonNode.Parse(utf8, documentOptions: new JsonDocumentOptions { MaxDepth = 256 }); }
        catch (JsonException) { return null; }
    }

    public static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text); }
        catch (JsonException) { return null; }
    }

    public static string? Str(this JsonNode? n, string key) =>
        n is JsonObject o && o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static string? AsStr(this JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static double? Num(this JsonNode? n, string key) => n is JsonObject o ? o[key].AsNum() : null;

    public static double? AsNum(this JsonNode? n)
    {
        if (n is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<string>(out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
        return null;
    }

    public static bool? Bool(this JsonNode? n, string key) =>
        n is JsonObject o && o[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public static JsonNode? Get(this JsonNode? n, string key) => n is JsonObject o ? o[key] : null;

    public static JsonNode? At(this JsonNode? n, int index) =>
        n is JsonArray a && index >= 0 && index < a.Count ? a[index] : null;

    public static JsonArray? Arr(this JsonNode? n, string key) => n is JsonObject o ? o[key] as JsonArray : null;
}

/// <summary>Byte-level string extraction from the prefix of oversize JSON lines.</summary>
public static class JsonSniff
{
    public static string? String(string key, ReadOnlySpan<byte> data, int after = 0)
    {
        int start = LocateValue(key, data, after);
        return start < 0 ? null : ReadString(data, start);
    }

    public static (string? Type, string? PayloadType) CodexKinds(ReadOnlySpan<byte> data)
    {
        var type = String("type", data);
        string? payloadType = null;
        int p = data.IndexOf("\"payload\":"u8);
        if (p >= 0) payloadType = String("type", data, p);
        return (type, payloadType);
    }

    public static int Find(ReadOnlySpan<byte> data, ReadOnlySpan<byte> needle, int from = 0)
    {
        if (from >= data.Length) return -1;
        int i = data[from..].IndexOf(needle);
        return i < 0 ? -1 : i + from;
    }

    private static int LocateValue(string key, ReadOnlySpan<byte> data, int from)
    {
        var needle = Encoding.UTF8.GetBytes($"\"{key}\"");
        int search = from;
        while (true)
        {
            int k = Find(data, needle, search);
            if (k < 0) return -1;
            int i = k + needle.Length;
            while (i < data.Length && (data[i] == ' ' || data[i] == '\t')) i++;
            if (i < data.Length && data[i] == ':')
            {
                i++;
                while (i < data.Length && (data[i] == ' ' || data[i] == '\t')) i++;
                return i;
            }
            search = k + 1;
        }
    }

    private static string? ReadString(ReadOnlySpan<byte> data, int start)
    {
        if (start >= data.Length || data[start] != '"') return null;
        var output = new List<byte>();
        int i = start + 1;
        while (i < data.Length)
        {
            byte c = data[i];
            if (c == '"') return Encoding.UTF8.GetString(output.ToArray());
            if (c == '\\' && i + 1 < data.Length)
            {
                byte e = data[i + 1];
                switch (e)
                {
                    case (byte)'n': output.Add(10); break;
                    case (byte)'t': output.Add(9); break;
                    case (byte)'r': output.Add(13); break;
                    case (byte)'u' when i + 5 < data.Length:
                        var hex = Encoding.ASCII.GetString(data.Slice(i + 2, 4));
                        if (int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var code))
                        {
                            output.AddRange(Encoding.UTF8.GetBytes(char.ConvertFromUtf32(code is >= 0xD800 and <= 0xDFFF ? 0xFFFD : code)));
                            i += 6;
                            continue;
                        }
                        output.Add(e);
                        break;
                    default: output.Add(e); break;
                }
                i += 2;
                continue;
            }
            output.Add(c);
            i++;
        }
        return null;
    }
}

public static class PathUtil
{
    /// <summary>Last path component, for either separator.</summary>
    public static string BaseName(string path)
    {
        var p = path.TrimEnd('/', '\\');
        int i = p.LastIndexOfAny(['/', '\\']);
        return i >= 0 ? p[(i + 1)..] : p;
    }
}
