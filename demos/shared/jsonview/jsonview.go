// Package jsonview serves JSON as a readable HTML page when a browser
// announces itself with Accept, so the demo apps can show a readable page
// while curl and every parsing script keep the compact contract. Colouring is
// done on the server so the page needs no JavaScript; the palette is the
// operator's.
package jsonview

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"regexp"
	"strings"
)

// WantsHTML is true when Accept lists text/html and does not list application/json before it.
// q-values and parameters are ignored; the first of the two media types that appears decides.
func WantsHTML(r *http.Request) bool {
	htmlIdx, jsonIdx := -1, -1
	for i, raw := range strings.Split(r.Header.Get("Accept"), ",") {
		media := strings.TrimSpace(raw)
		if j := strings.IndexByte(media, ';'); j >= 0 {
			media = strings.TrimSpace(media[:j])
		}
		switch media {
		case "text/html":
			if htmlIdx < 0 {
				htmlIdx = i
			}
		case "application/json":
			if jsonIdx < 0 {
				jsonIdx = i
			}
		}
	}
	if htmlIdx < 0 {
		return false
	}
	if jsonIdx >= 0 && jsonIdx < htmlIdx {
		return false
	}
	return true
}

var (
	jsonHTMLKeyRe  = regexp.MustCompile(`^(\s*)(&#34;[^&]*?&#34;|"[^"]*")(:)`)
	jsonHTMLStrRe  = regexp.MustCompile(`&#34;.*?&#34;|"[^"]*"`)
	jsonHTMLBoolRe = regexp.MustCompile(`true|false|null`)
	jsonHTMLNumRe  = regexp.MustCompile(`-?\d+(\.\d+)?([eE][-+]?\d+)?`)
)

func colorJSON(pretty string) string {
	wrap := func(s string, re *regexp.Regexp, class string) (string, bool) {
		loc := re.FindStringIndex(s)
		if loc == nil {
			return s, false
		}
		return s[:loc[0]] + `<span class="` + class + `">` + s[loc[0]:loc[1]] + `</span>` + s[loc[1]:], true
	}
	var b strings.Builder
	for i, line := range strings.Split(pretty, "\n") {
		if i > 0 {
			b.WriteByte('\n')
		}
		esc := html.EscapeString(line)
		m := jsonHTMLKeyRe.FindStringSubmatchIndex(esc)
		if m == nil {
			b.WriteString(esc)
			continue
		}
		b.WriteString(esc[m[2]:m[3]])
		b.WriteString(`<span class="k">`)
		b.WriteString(esc[m[4]:m[5]])
		b.WriteString(`</span>`)
		b.WriteString(esc[m[6]:m[7]])
		rest := esc[m[1]:]
		if r, ok := wrap(rest, jsonHTMLStrRe, "s"); ok {
			b.WriteString(r)
			continue
		}
		if r, ok := wrap(rest, jsonHTMLBoolRe, "b"); ok {
			b.WriteString(r)
			continue
		}
		if r, ok := wrap(rest, jsonHTMLNumRe, "n"); ok {
			b.WriteString(r)
			continue
		}
		b.WriteString(rest)
	}
	return b.String()
}

// Write sends compact as application/json, or as the HTML page when WantsHTML.
func Write(w http.ResponseWriter, r *http.Request, code int, compact []byte, title string) {
	if WantsHTML(r) {
		writeHTML(w, r, code, compact, title)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(compact)
}

// WriteValue marshals v as compact JSON (a trailing newline, Encoder-equivalent)
// and calls Write. A marshal error is a 500 with a plain-text body, as http.Error does.
func WriteValue(w http.ResponseWriter, r *http.Request, code int, v any, title string) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	b = append(b, '\n')
	Write(w, r, code, b, title)
}

func writeHTML(w http.ResponseWriter, r *http.Request, code int, compact []byte, title string) {
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, compact, "", "  "); err != nil {
		pretty.Reset()
		pretty.Write(compact)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	fmt.Fprintf(w, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<style>
body{background:#dde3ea;margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#2a3441}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 24px;background:#3a4a5c;border-bottom:1px solid #2f3d4d;color:#e6ebf0}
header .name{font-weight:600;font-size:15px}
header .req{color:#b9c4d0;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
main{max-width:880px;margin:24px auto;padding:0 16px}
.card{background:#faf8f4;border:1px solid #c5ccd5;border-radius:8px;box-shadow:0 1px 3px rgba(27,31,36,.06)}
pre{margin:0;padding:18px 20px;font:13.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#2a3441;white-space:pre-wrap;word-break:break-word;overflow-x:hidden}
.k{color:#2f5d8a}.s{color:#5c7a4a}.n,.b{color:#8a5a86}
.note{color:#5b6875;font-size:12.5px}
</style>
</head>
<body>
<header><span class="name">%s</span><span class="req">%s %s</span></header>
<main>
<div class="card"><pre>%s</pre></div>
<p class="note">Browsers get this page (Accept: text/html); curl and scripts get the same JSON, compact.</p>
</main>
</body>
</html>
`, html.EscapeString(title), html.EscapeString(title), html.EscapeString(r.Method), html.EscapeString(r.URL.Path), colorJSON(pretty.String()))
}
