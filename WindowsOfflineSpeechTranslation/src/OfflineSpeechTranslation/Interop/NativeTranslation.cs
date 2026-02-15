using System.Runtime.InteropServices;
using System.Text;

namespace OfflineSpeechTranslation.Interop;

internal static class NativeTranslation
{
    // Native DLL built from src/OfflineSpeechTranslation.NativeTranslation
    private const string DllName = "OfflineSpeechTranslation.NativeTranslation";

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int OST_CreateTranslator(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string modelDirUtf8,
        out nint outHandle,
        byte[] errorBuf,
        int errorBufLen);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int OST_DestroyTranslator(nint handle);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int OST_TranslateUtf8(
        nint handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string inputUtf8,
        byte[]? outBuf,
        int outBufLen,
        out int outRequiredLen,
        byte[] errorBuf,
        int errorBufLen);

    internal sealed class Translator : IDisposable
    {
        private nint _handle;

        private Translator(nint handle)
        {
            _handle = handle;
        }

        public static Translator? TryCreate(string modelDir, out string? error)
        {
            error = null;
            try
            {
                var errBuf = new byte[8 * 1024];
                int rc = OST_CreateTranslator(modelDir, out var handle, errBuf, errBuf.Length);
                if (rc != 0 || handle == 0)
                {
                    error = DecodeError(errBuf);
                    return null;
                }
                return new Translator(handle);
            }
            catch (DllNotFoundException e)
            {
                error = $"Native translation DLL not found: {e.Message}";
                return null;
            }
            catch (EntryPointNotFoundException e)
            {
                error = $"Native translation entrypoint missing: {e.Message}";
                return null;
            }
            catch (Exception e)
            {
                error = e.Message;
                return null;
            }
        }

        public string Translate(string input)
        {
            if (_handle == 0) throw new ObjectDisposedException(nameof(Translator));
            var normalized = (input ?? "").Trim();
            if (normalized.Length == 0) return "";

            var errBuf = new byte[8 * 1024];

            // First pass: query required output length
            int rc = OST_TranslateUtf8(_handle, normalized, null, 0, out int required, errBuf, errBuf.Length);
            if (rc != 0)
                throw new InvalidOperationException(DecodeError(errBuf));

            if (required <= 0) return "";
            var outBuf = new byte[required];
            rc = OST_TranslateUtf8(_handle, normalized, outBuf, outBuf.Length, out required, errBuf, errBuf.Length);
            if (rc != 0)
                throw new InvalidOperationException(DecodeError(errBuf));

            return Encoding.UTF8.GetString(outBuf).Trim();
        }

        public void Dispose()
        {
            var handle = _handle;
            _handle = 0;
            if (handle != 0)
            {
                try { _ = OST_DestroyTranslator(handle); }
                catch { /* best-effort */ }
            }
        }
    }

    private static string DecodeError(byte[] buf)
    {
        try
        {
            var s = Encoding.UTF8.GetString(buf);
            var zero = s.IndexOf('\0');
            if (zero >= 0) s = s[..zero];
            return s.Trim();
        }
        catch
        {
            return "Unknown native translation error.";
        }
    }
}
