// Wget(url, file) saves an http:// URL to a file; HttpServe(port, dir) is a tiny
// HTTP/1.0 file server for a directory of C: (GET and HEAD, directory listings,
// one task per connection, Connection: close).
//   Wget("http://example.com/", "C:/Example.html");
//   HttpServe(80, "C:/");     under coolvm --net-forward 8080:80: curl localhost:8080/Init.HC

I64 Wget(U8 *url, U8 *file = NULL)
{//GET url and write the body to file (default: the URL's last path part, or index.html). Bytes or -1.
    I64 len, status, blen;
    U8 *res = HttpFetch(url, &len, &status), *body, *name, *p, buf[256];
    if (!res)
        return -1;
    if (status != 200) {
        body = StrFind("\r\n", res);
        if (body)
            *body = 0;
        Print("Wget: %s\n", res);
        Free(res);
        return -1;
    }
    body = StrFind("\r\n\r\n", res);
    if (body)
        body += 4;
    else
        body = res + len;
    blen = len - (body - res);
    name = file;
    if (!name) {
        p = url;
        if (!StrNCmp(p, "http://", 7))
            p += 7;
        p = StrFirstOcc(p, "/");
        name = "index.html";
        if (p && StrLastOcc(p, "/")[1]) {
            StrCpy(buf, StrLastOcc(p, "/") + 1);
            if (p = StrFirstOcc(buf, "?"))
                *p = 0;
            if (*buf)
                name = buf;
        }
    }
    if (FileWrite(name, body, blen) == INVALID_CLUS) {
        Print("Wget: cannot write %s\n", name);
        Free(res);
        return -1;
    }
    Print("Wget: %d bytes saved to %s\n", blen, name);
    Free(res);
    return blen;
}

// ---- server ---------------------------------------------------------------

class CHttpConn
{
    CTcb *tcb;
    U8 *dir;
};

U8 *HttpMime(U8 *name)
{
    U8 *ext = StrLastOcc(name, ".");
    if (!ext)
        return "text/plain; charset=utf-8";
    ext++;
    if (!StrICmp(ext, "html") || !StrICmp(ext, "htm"))
        return "text/html; charset=utf-8";
    if (!StrICmp(ext, "png"))
        return "image/png";
    if (!StrICmp(ext, "jpg") || !StrICmp(ext, "jpeg"))
        return "image/jpeg";
    if (!StrICmp(ext, "gif"))
        return "image/gif";
    if (!StrICmp(ext, "css"))
        return "text/css";
    if (!StrICmp(ext, "js"))
        return "text/javascript";
    if (!StrICmp(ext, "json"))
        return "application/json";
    if (!StrICmp(ext, "BIN") || !StrICmp(ext, "img") || !StrICmp(ext, "zip") || !StrICmp(ext, "Image"))
        return "application/octet-stream";
    return "text/plain; charset=utf-8";
}

U0 HttpReply(CTcb *t, I64 status, U8 *reason, U8 *type, U8 *body, I64 len, Bool head)
{
    U8 *hdr = MStrPrint("HTTP/1.0 %d %s\r\nServer: coolcom\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                        "Connection: close\r\n\r\n", status, reason, type, len);
    TcpSend(t, hdr, StrLen(hdr));
    Free(hdr);
    if (!head && len)
        TcpSend(t, body, len);
}

U0 HttpError(CTcb *t, I64 status, U8 *reason, Bool head)
{
    U8 *body = MStrPrint("%d %s\n", status, reason);
    HttpReply(t, status, reason, "text/plain", body, StrLen(body), head);
    Free(body);
}

Bool HttpHex2(U8 *s, I64 *_v)
{//Two hex digits.
    I64 i, c, v = 0;
    for (i = 0; i < 2; i++) {
        c = ToUpper(s[i]);
        if (c >= '0' && c <= '9')
            v = v << 4 | (c - '0');
        else if (c >= 'A' && c <= 'F')
            v = v << 4 | (c - 'A' + 10);
        else
            return FALSE;
    }
    *_v = v;
    return TRUE;
}

Bool HttpUnescape(U8 *s)
{//Decode %XX in place and stop at ? or #; FALSE for a path that could leave the served directory.
    U8 *d = s, *start = s;
    I64 h;
    while (*s && *s != '?' && *s != '#') {
        if (*s == '%') {
            if (!HttpHex2(s + 1, &h) || !h)
                return FALSE;
            *d++ = h;
            s += 3;
        } else
            *d++ = *s++;
    }
    *d = 0;
    return !StrFind("..", start) && !StrFind("\\", start) && !StrFind(":", start);
}

U0 HttpAppend(U8 **_out, I64 *_len, I64 *_cap, U8 *s)
{//Append s (Freed) to a growing buffer.
    I64 n = StrLen(s);
    U8 *p;
    if (*_len + n + 1 > *_cap) {
        *_cap = 2 * *_cap + n;
        p = MAlloc(*_cap);
        MemCpy(p, *_out, *_len);
        Free(*_out);
        *_out = p;
    }
    MemCpy(*_out + *_len, s, n + 1);
    *_len += n;
    Free(s);
}

U8 *HttpListing(U8 *path, U8 *url, I64 *_len)
{//An HTML directory listing of path (url: how the client named it, ending in /).
    CDirEntry *de, *de1;
    U8 *mask = MStrPrint("%s/*", path), *out = MAlloc(4096);
    I64 cap = 4096, len = 0;
    *out = 0;
    HttpAppend(&out, &len, &cap, MStrPrint("<!doctype html>\n<title>Index of %s</title>\n<h1>Index of %s</h1>\n<pre>\n", url, url));
    de1 = de = FilesFind(mask);
    Free(mask);
    for (; de; de = de->next)
        if (StrCmp(de->name, ".") && StrCmp(de->name, "..")) {
            if (de->attr & RS_ATTR_DIR)
                HttpAppend(&out, &len, &cap, MStrPrint("<a href=\"%s/\">%s/</a>\n", de->name, de->name));
            else
                HttpAppend(&out, &len, &cap, MStrPrint("<a href=\"%s\">%s</a> %d\n", de->name, de->name, de->size));
        }
    DirTreeDel(de1);
    HttpAppend(&out, &len, &cap, StrNew("</pre>\n"));
    *_len = len;
    return out;
}

U0 HttpServeConn(CHttpConn *c)
{//One request: read the head, answer, close.
    CTcb *t = c->tcb;
    U8 req[4096], *url, *p, *path, *data;
    I64 n, len = 0, deadline = jiffies + 10000, size;
    Bool head;
    req[0] = 0;
    while (len < 4095 && !StrFind("\r\n\r\n", req) && !StrFind("\n\n", req)) {
        n = TcpRecv(t, req + len, 4095 - len, MaxI64(deadline - jiffies, 0));
        if (n <= 0)
            break;
        len += n;
        req[len] = 0;
    }
    head = !StrNCmp(req, "HEAD ", 5);
    if (StrNCmp(req, "GET ", 4) && !head) {
        if (len)
            HttpError(t, 501, "Not Implemented", FALSE);
        goto http_done;
    }
    url = StrFirstOcc(req, " ") + 1;
    if (p = StrFirstOcc(url, " "))
        *p = 0;
    if (p = StrFirstOcc(url, "\r"))
        *p = 0;
    if (p = StrFirstOcc(url, "\n"))
        *p = 0;
    if (*url != '/' || !HttpUnescape(url)) {
        HttpError(t, 400, "Bad Request", head);
        goto http_done;
    }
    path = MStrPrint("%s%s", c->dir, url);
    n = StrLen(path);
    while (n && path[n - 1] == '/')
        path[--n] = 0;  // C:/a/ -> C:/a, C:/ -> C:
    if (IsDir(path)) {
        if (url[StrLen(url) - 1] != '/') {
            data = MStrPrint("HTTP/1.0 301 Moved Permanently\r\nLocation: %s/\r\nContent-Length: 0\r\n"
                             "Connection: close\r\n\r\n", url);
            TcpSend(t, data, StrLen(data));
        } else {
            data = HttpListing(path, url, &size);
            HttpReply(t, 200, "OK", "text/html; charset=utf-8", data, size, head);
        }
        Free(data);
    } else if (FileFind(path) && (data = FileRead(path, &size))) {
        HttpReply(t, 200, "OK", HttpMime(path), data, size, head);
        Free(data);
    } else
        HttpError(t, 404, "Not Found", head);
    Free(path);
http_done:
    TcpClose(t);
    Free(c->dir);
    Free(c);
}

U0 HttpListen(CHttpConn *l)
{
    CHttpConn *c;
    CTcb *t;
    while (TRUE) {
        t = TcpAccept(l->tcb);
        c = CAlloc(sizeof(CHttpConn));
        c->tcb = t;
        c->dir = StrNew(l->dir);
        // Core 0, like the shells: file system calls never run concurrently with theirs.
        Spawn(&HttpServeConn, c, "HttpConn", 0);
    }
}

CTask *HttpServe(I64 port = 80, U8 *dir = "C:")
{//Serve the files under dir over HTTP on port (in the background); Kill the returned task to stop.
    CHttpConn *l;
    CTcb *t;
    I64 n;
    if (!IsDir(dir)) {
        Print("HttpServe: no directory %s\n", dir);
        return NULL;
    }
    if (!(t = TcpListen(port))) {
        Print("HttpServe: port %d is in use\n", port);
        return NULL;
    }
    l = CAlloc(sizeof(CHttpConn));
    l->tcb = t;
    l->dir = StrNew(dir);
    n = StrLen(l->dir);
    while (n && l->dir[n - 1] == '/')
        l->dir[--n] = 0;
    Print("HttpServe: %s on port %d\n", dir, port);
    return Spawn(&HttpListen, l, "HttpServe", 0);
}
