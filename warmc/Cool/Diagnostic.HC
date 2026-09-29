// Shared host/kernel source location and caret renderer.
U0 WDiagnostic(CWUnit *u)
{
    CWToken *t = u->error_token;
    I64 line = 1, col = 1, i, start = 0, end;
    U8 *s;
    if (!t) {Print("%s: %s\n", u->error_kind, u->error_message); return;}
    s = t->source->text;
    for (i = 0; i < t->start; i++) {if (s[i] == '\n') {line++; col = 1; start = i + 1;} else col++;}
    end = start; while (s[end] && s[end] != '\n' && s[end] != '\r') end++;
    Print("%s:%d:%d: %s: %s\n", t->source->path, line, col, u->error_kind, u->error_message);
    Print("%s\n", WText(u, s + start, end - start));
    for (i = 1; i < col; i++) {if (s[(start + i) - 1] == '\t') Print("\t"); else Print(" ");}
    Print("^\n");
}
U8 *WDiagnosticJson(CWUnit *u)
{
    CWBuffer *b = WAlloc(u, sizeof(CWBuffer)); CWToken *t = u->error_token;
    I64 i, line = 1, col = 0;
    WGPut(u, b, "{\"kind\":"); WGPut(u, b, WGQuote(u, u->error_kind));
    WGPut(u, b, ",\"text\":[{\"type\":\"text\",\"content\":"); WGPut(u, b, WGQuote(u, u->error_message)); WGPut(u, b, "}]");
    if (t) {
        for (i = 0; i < t->start; i++) {if (t->source->text[i] == '\n') {line++; col = 0;} else col++;}
        WGPut(u, b, ",\"span\":{\"filename\":"); WGPut(u, b, WGQuote(u, t->source->path));
        WGPut(u, b, WG3(u, ",\"startp\":{\"line\":", WGDec(u, line), WG3(u, ",\"column\":", WGDec(u, col), "}")));
        WGPut(u, b, WG3(u, ",\"end\":{\"line\":", WGDec(u, line), WG3(u, ",\"column\":", WGDec(u, col + t->end - t->start), "}}")));
    } else WGPut(u, b, ",\"span\":null");
    WGPut(u, b, "}\n"); return b->data;
}
