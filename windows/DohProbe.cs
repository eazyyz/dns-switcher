using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// Windows 11 WinHTTP negotiates HTTP/2 and preserves certificate/SNI validation
// while RESOLUTION_HOSTNAME pins the connection to the resolver being tested.
public static class DohProbe
{
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr WinHttpOpen(string agent, uint access, string proxy, string bypass, uint flags);
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr WinHttpConnect(IntPtr session, string host, ushort port, uint reserved);
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr WinHttpOpenRequest(IntPtr connection, string verb, string path, string version, string referer, IntPtr accepts, uint flags);
    [DllImport("winhttp.dll", SetLastError=true)] static extern bool WinHttpSetOption(IntPtr handle, uint option, byte[] value, uint length);
    [DllImport("winhttp.dll", SetLastError=true)] static extern bool WinHttpSetTimeouts(IntPtr handle, int resolve, int connect, int send, int receive);
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool WinHttpSendRequest(IntPtr request, string headers, uint headerLength, byte[] data, uint dataLength, uint totalLength, IntPtr context);
    [DllImport("winhttp.dll", SetLastError=true)] static extern bool WinHttpReceiveResponse(IntPtr request, IntPtr reserved);
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool WinHttpQueryHeaders(IntPtr request, uint info, string name, byte[] buffer, ref uint size, IntPtr index);
    [DllImport("winhttp.dll", SetLastError=true)] static extern bool WinHttpReadData(IntPtr request, byte[] buffer, uint length, out uint read);
    [DllImport("winhttp.dll")] static extern bool WinHttpCloseHandle(IntPtr handle);
    private static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    private static IntPtr CheckHandle(IntPtr handle) { if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error()); return handle; }
    public static byte[] Query(string endpoint, string address)
    {
        var uri = new Uri(endpoint);
        if (uri.Scheme != "https") throw new ArgumentException("HTTPS required");
        System.Net.IPAddress.Parse(address);
        IntPtr session=IntPtr.Zero, connection=IntPtr.Zero, request=IntPtr.Zero;
        try {
            session=CheckHandle(WinHttpOpen("DNS-Switcher/1.0", 1, null, null, 0));
            Check(WinHttpSetTimeouts(session, 3000, 5000, 5000, 8000));
            connection=CheckHandle(WinHttpConnect(session, uri.DnsSafeHost, (ushort)uri.Port, 0));
            request=CheckHandle(WinHttpOpenRequest(connection, "POST", uri.PathAndQuery, null, null, IntPtr.Zero, 0x00800000));
            Check(WinHttpSetOption(request, 133, BitConverter.GetBytes(1u), 4)); // HTTP/2
            Check(WinHttpSetOption(request, 63, BitConverter.GetBytes(2u), 4)); // no redirects
            byte[] target=Encoding.Unicode.GetBytes(address + "\0");
            Check(WinHttpSetOption(request, 165, target, (uint)target.Length));
            byte[] query={0x12,0x34,1,0,0,1,0,0,0,0,0,0,7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1};
            string headers="Content-Type: application/dns-message\r\nAccept: application/dns-message\r\n";
            Check(WinHttpSendRequest(request, headers, (uint)headers.Length, query, (uint)query.Length, (uint)query.Length, IntPtr.Zero));
            Check(WinHttpReceiveResponse(request, IntPtr.Zero));
            byte[] status=new byte[4]; uint size=4;
            Check(WinHttpQueryHeaders(request, 19 | 0x20000000, null, status, ref size, IntPtr.Zero));
            if (BitConverter.ToUInt32(status,0)!=200) throw new IOException("DoH HTTP " + BitConverter.ToUInt32(status,0));
            byte[] contentType=new byte[1024]; size=(uint)contentType.Length;
            Check(WinHttpQueryHeaders(request, 1, null, contentType, ref size, IntPtr.Zero));
            string mime=Encoding.Unicode.GetString(contentType,0,(int)size).TrimEnd('\0').Split(';')[0].Trim();
            if (!mime.Equals("application/dns-message",StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid DoH content type: " + mime);
            using (var output=new MemoryStream()) {
                byte[] buffer=new byte[4096]; uint read;
                do {
                    Check(WinHttpReadData(request, buffer, (uint)buffer.Length, out read));
                    if (output.Length + read > 65535) throw new IOException("DoH response too large");
                    output.Write(buffer,0,(int)read);
                } while (read>0);
                return output.ToArray();
            }
        } finally {
            if(request!=IntPtr.Zero) WinHttpCloseHandle(request);
            if(connection!=IntPtr.Zero) WinHttpCloseHandle(connection);
            if(session!=IntPtr.Zero) WinHttpCloseHandle(session);
        }
    }
}
