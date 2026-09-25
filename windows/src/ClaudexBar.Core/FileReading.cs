namespace ClaudexBar.Core;

public readonly record struct FileStat(long Size, DateTimeOffset Modified, DateTimeOffset Created, bool IsDirectory);

/// <summary>Read-only file access that never blocks the tools writing these files.</summary>
public static class FileReading
{
    public static FileStat? Stat(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                var d = new DirectoryInfo(path);
                return new FileStat(0, d.LastWriteTimeUtc, d.CreationTimeUtc, true);
            }
            var f = new FileInfo(path);
            if (!f.Exists) return null;
            return new FileStat(f.Length, f.LastWriteTimeUtc, f.CreationTimeUtc, false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static FileStream Open(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.None);

    public static byte[]? Read(string path, long offset, int length)
    {
        try
        {
            using var fs = Open(path);
            fs.Seek(offset, SeekOrigin.Begin);
            var buffer = new byte[length];
            int total = 0;
            while (total < length)
            {
                int n = fs.Read(buffer, total, length - total);
                if (n == 0) break;
                total += n;
            }
            return total == length ? buffer : buffer[..total];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    public static byte[]? ReadAll(string path, int maxBytes)
    {
        var st = Stat(path);
        if (st is not { IsDirectory: false } s || s.Size > maxBytes) return null;
        return Read(path, 0, (int)s.Size);
    }

    public static string[] List(string dir)
    {
        try { return Directory.Exists(dir) ? Directory.GetFileSystemEntries(dir).Select(PathUtil.BaseName).ToArray() : []; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }
}

/// <summary>A JSONL line: complete, or the prefix of a line too large to buffer.</summary>
public readonly record struct JsonLine(byte[] Bytes, int TotalBytes, bool IsOversize)
{
    public static JsonLine Complete(byte[] b) => new(b, b.Length, false);
    public static JsonLine Oversize(byte[] prefix, int total) => new(prefix, total, true);
    public string Text => System.Text.Encoding.UTF8.GetString(Bytes);
}

/// <summary>Incremental '\n' framing with a per-line cap; oversize lines keep a prefix.</summary>
public sealed class LineFramer(int maxLineBytes, int prefixBytes = 16 * 1024)
{
    private readonly List<byte> _buffer = [];
    private byte[]? _oversizePrefix;
    private int _oversizeTotal;

    public int PendingBytes => _oversizePrefix is not null ? _oversizeTotal : _buffer.Count;

    public List<JsonLine> Push(ReadOnlySpan<byte> chunk)
    {
        var lines = new List<JsonLine>();
        int start = 0;
        while (start < chunk.Length)
        {
            int nl = chunk[start..].IndexOf((byte)'\n');
            if (nl >= 0)
            {
                var piece = chunk.Slice(start, nl);
                if (_oversizePrefix is not null)
                {
                    lines.Add(JsonLine.Oversize(_oversizePrefix, _oversizeTotal + piece.Length));
                    _oversizePrefix = null;
                    _oversizeTotal = 0;
                }
                else
                {
                    _buffer.AddRange(piece.ToArray());
                    var line = _buffer.ToArray();
                    _buffer.Clear();
                    if (line.Length > maxLineBytes)
                        lines.Add(JsonLine.Oversize(line[..prefixBytes], line.Length));
                    else
                    {
                        if (line.Length > 0 && line[^1] == '\r') line = line[..^1];
                        if (line.Length > 0) lines.Add(JsonLine.Complete(line));
                    }
                }
                start += nl + 1;
            }
            else
            {
                var piece = chunk[start..];
                if (_oversizePrefix is not null) _oversizeTotal += piece.Length;
                else
                {
                    _buffer.AddRange(piece.ToArray());
                    if (_buffer.Count > maxLineBytes)
                    {
                        _oversizePrefix = _buffer.Take(prefixBytes).ToArray();
                        _oversizeTotal = _buffer.Count;
                        _buffer.Clear();
                    }
                }
                start = chunk.Length;
            }
        }
        return lines;
    }
}

/// <summary>Follows an append-only JSONL file from a saved offset.</summary>
public sealed class ForwardTailer(string path, DateTimeOffset created, long offset, int maxLineBytes, long maxGap = 8L << 20)
{
    public enum Status { Lines, Unchanged, Missing, NeedsBootstrap }

    private readonly LineFramer _framer = new(maxLineBytes);
    public string Path { get; } = path;
    public long ReadOffset { get; private set; } = offset;
    private DateTimeOffset _created = created;

    public (Status Status, List<JsonLine> Lines) Poll()
    {
        var st = FileReading.Stat(Path);
        if (st is not { IsDirectory: false } s) return (Status.Missing, []);
        if (s.Created != _created && _created != default) return (Status.NeedsBootstrap, []);
        if (s.Size < ReadOffset) return (Status.NeedsBootstrap, []);
        if (s.Size == ReadOffset) return (Status.Unchanged, []);
        if (s.Size - ReadOffset > maxGap) return (Status.NeedsBootstrap, []);
        var lines = new List<JsonLine>();
        while (ReadOffset < s.Size)
        {
            int want = (int)Math.Min(1 << 20, s.Size - ReadOffset);
            var data = FileReading.Read(Path, ReadOffset, want);
            if (data is null || data.Length == 0) break;
            ReadOffset += data.Length;
            lines.AddRange(_framer.Push(data));
        }
        _created = s.Created;
        return lines.Count == 0 ? (Status.Unchanged, lines) : (Status.Lines, lines);
    }
}

/// <summary>Reads complete lines backwards from the end of a file within a byte budget.</summary>
public static class BackwardScanner
{
    public sealed record Result(List<JsonLine> Lines, bool ReachedStop, bool ReachedStart, bool Exhausted, long EndOffset,
        int BytesRead, DateTimeOffset Created);

    public static Result? Scan(string path, int budget, int maxLineBytes, Func<JsonLine, bool> stop, int chunk = 256 * 1024,
        int prefixBytes = 16 * 1024)
    {
        var st = FileReading.Stat(path);
        if (st is not { IsDirectory: false } s) return null;
        var state = new State(maxLineBytes, prefixBytes, stop);
        long pos = s.Size;
        int bytesRead = 0;
        long? end = null;
        while (pos > 0)
        {
            if (bytesRead >= budget) { state.Exhausted = true; break; }
            int n = (int)Math.Min(chunk, pos);
            var data = FileReading.Read(path, pos - n, n);
            if (data is null || data.Length != n) { state.Exhausted = true; break; }
            bytesRead += n;
            pos -= n;
            if (end is null)
            {
                int nl = Array.LastIndexOf(data, (byte)'\n');
                if (nl < 0) continue;
                end = pos + nl + 1;
                if (state.Process(data.AsSpan(0, nl))) break;
            }
            else if (state.Process(data)) break;
        }
        if (end is not null && !state.ReachedStop && !state.Exhausted) state.FlushFirstLine();
        var lines = state.NewestFirst;
        lines.Reverse();
        return new Result(lines, state.ReachedStop, end is not null && !state.ReachedStop && !state.Exhausted,
            state.Exhausted, end ?? 0, bytesRead, s.Created);
    }

    private sealed class State(int maxLineBytes, int prefixBytes, Func<JsonLine, bool> stop)
    {
        public readonly List<JsonLine> NewestFirst = [];
        private List<byte> _tail = [];
        private int _tailTotal;
        public bool ReachedStop;
        public bool Exhausted;

        public bool Process(ReadOnlySpan<byte> slice)
        {
            int segEnd = slice.Length;
            while (true)
            {
                int nl = slice[..segEnd].LastIndexOf((byte)'\n');
                if (nl < 0) break;
                if (Emit(slice.Slice(nl + 1, segEnd - nl - 1))) return true;
                segEnd = nl;
            }
            var part = slice[..segEnd];
            _tailTotal += part.Length;
            _tail.InsertRange(0, part.ToArray());
            if (_tailTotal > maxLineBytes && _tail.Count > prefixBytes) _tail = _tail.Take(prefixBytes).ToList();
            return false;
        }

        public void FlushFirstLine() => Emit([]);

        private bool Emit(ReadOnlySpan<byte> head)
        {
            int total = head.Length + _tailTotal;
            try
            {
                if (total <= 0) return false;
                JsonLine line;
                if (total > maxLineBytes)
                {
                    var prefix = new List<byte>(head[..Math.Min(prefixBytes, head.Length)].ToArray());
                    if (prefix.Count < prefixBytes) prefix.AddRange(_tail.Take(prefixBytes - prefix.Count));
                    line = JsonLine.Oversize(prefix.ToArray(), total);
                }
                else
                {
                    var bytes = new List<byte>(head.ToArray());
                    bytes.AddRange(_tail);
                    if (bytes.Count > 0 && bytes[^1] == '\r') bytes.RemoveAt(bytes.Count - 1);
                    if (bytes.Count == 0) return false;
                    line = JsonLine.Complete(bytes.ToArray());
                }
                NewestFirst.Add(line);
                if (stop(line)) { ReachedStop = true; return true; }
                return false;
            }
            finally
            {
                _tail.Clear();
                _tailTotal = 0;
            }
        }
    }
}
