//! Local, zero-network plain-text extraction for encrypted note assets
//! (PDF via macOS PDFKit in memory, DOCX/XLSX/PPTX via zip + roxmltree, and UTF-8 text).
use std::io::{Cursor, Read};

const MAX_XML_ENTRY_BYTES: u64 = 20 * 1024 * 1024;
const MAX_EXTRACTED_CHARS: usize = 500_000;
const MAX_SHEETS_OR_SLIDES: usize = 64;

/// Detects an accurate MIME type from magic bytes and filename extension.
pub(crate) fn detect_mime(name: &str, head: &[u8]) -> &'static str {
    if head.starts_with(b"\x89PNG\r\n\x1a\n") {
        return "image/png";
    }
    if head.starts_with(b"\xff\xd8\xff") {
        return "image/jpeg";
    }
    if head.starts_with(b"GIF87a") || head.starts_with(b"GIF89a") {
        return "image/gif";
    }
    if head.starts_with(b"RIFF") && head.get(8..12) == Some(b"WEBP") {
        return "image/webp";
    }
    if head.starts_with(b"%PDF-") {
        return "application/pdf";
    }
    let ext = name
        .rsplit('.')
        .next()
        .filter(|_| name.contains('.'))
        .map(|s| s.to_ascii_lowercase());
    match ext.as_deref() {
        Some("pdf") => "application/pdf",
        Some("docx") => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        Some("xlsx") => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        Some("pptx") => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        Some("doc") => "application/msword",
        Some("xls") => "application/vnd.ms-excel",
        Some("ppt") => "application/vnd.ms-powerpoint",
        Some("md" | "markdown") => "text/markdown",
        Some("txt" | "log" | "env" | "ini" | "conf" | "cfg") => "text/plain",
        Some("csv") => "text/csv",
        Some("json") => "application/json",
        Some("yaml" | "yml") => "text/yaml",
        Some("xml") => "application/xml",
        Some("html" | "htm") => "text/html",
        Some("zip") => "application/zip",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => {
            if !head.is_empty() && !head.contains(&0) && std::str::from_utf8(head).is_ok() {
                "text/plain"
            } else {
                "application/octet-stream"
            }
        }
    }
}

pub(crate) fn can_extract_text(name: &str, mime: &str) -> bool {
    let ext = name
        .rsplit('.')
        .next()
        .filter(|_| name.contains('.'))
        .map(|s| s.to_ascii_lowercase());
    matches!(
        ext.as_deref(),
        Some(
            "pdf"
                | "docx"
                | "xlsx"
                | "pptx"
                | "txt"
                | "md"
                | "markdown"
                | "csv"
                | "json"
                | "yaml"
                | "yml"
                | "xml"
                | "log"
        )
    ) || mime.starts_with("text/")
        || matches!(
            mime,
            "application/pdf"
                | "application/json"
                | "application/xml"
                | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                | "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        )
}

fn clamp_text(raw: String) -> String {
    let trimmed = raw.trim();
    if trimmed.chars().count() <= MAX_EXTRACTED_CHARS {
        trimmed.to_owned()
    } else {
        trimmed.chars().take(MAX_EXTRACTED_CHARS).collect()
    }
}

/// Extracts bounded plain text locally in memory (never writes temp files or calls external network).
pub(crate) fn extract_text(name: &str, mime: &str, bytes: &[u8]) -> Result<String, String> {
    let ext = name
        .rsplit('.')
        .next()
        .filter(|_| name.contains('.'))
        .map(|s| s.to_ascii_lowercase());
    if mime == "application/pdf" || ext.as_deref() == Some("pdf") || bytes.starts_with(b"%PDF-") {
        return extract_pdf(bytes).map(clamp_text);
    }
    if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        || ext.as_deref() == Some("docx")
    {
        return extract_docx(bytes).map(clamp_text);
    }
    if mime == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        || ext.as_deref() == Some("xlsx")
    {
        return extract_xlsx(bytes).map(clamp_text);
    }
    if mime == "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        || ext.as_deref() == Some("pptx")
    {
        return extract_pptx(bytes).map(clamp_text);
    }
    if !bytes.contains(&0) {
        if let Ok(text) = std::str::from_utf8(bytes) {
            return Ok(clamp_text(text.to_owned()));
        }
    }
    Err("TextOnly".into())
}

fn read_zip_entry(
    archive: &mut zip::ZipArchive<Cursor<&[u8]>>,
    entry_name: &str,
) -> Result<String, String> {
    let file = archive
        .by_name(entry_name)
        .map_err(|_| "UnsupportedFormat".to_string())?;
    let mut buf = Vec::new();
    file.take(MAX_XML_ENTRY_BYTES + 1)
        .read_to_end(&mut buf)
        .map_err(|_| "UnsupportedFormat".to_string())?;
    if buf.len() as u64 > MAX_XML_ENTRY_BYTES {
        return Err("AssetTooLarge".into());
    }
    String::from_utf8(buf).map_err(|_| "UnsupportedFormat".to_string())
}

fn extract_docx(bytes: &[u8]) -> Result<String, String> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| "UnsupportedFormat".to_string())?;
    let xml = read_zip_entry(&mut archive, "word/document.xml")?;
    let doc = roxmltree::Document::parse(&xml).map_err(|_| "UnsupportedFormat".to_string())?;
    let mut lines = Vec::new();
    for node in doc.descendants() {
        if node.has_tag_name("p") {
            let mut line = String::new();
            for child in node.descendants() {
                if child.has_tag_name("t") {
                    if let Some(t) = child.text() {
                        line.push_str(t);
                    }
                } else if child.has_tag_name("tab") {
                    line.push('\t');
                } else if child.has_tag_name("br") || child.has_tag_name("cr") {
                    line.push('\n');
                }
            }
            if !line.trim().is_empty() {
                lines.push(line);
            }
        }
    }
    Ok(lines.join("\n"))
}

fn extract_xlsx(bytes: &[u8]) -> Result<String, String> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| "UnsupportedFormat".to_string())?;
    let mut shared = Vec::new();
    if let Ok(sst_xml) = read_zip_entry(&mut archive, "xl/sharedStrings.xml") {
        if let Ok(doc) = roxmltree::Document::parse(&sst_xml) {
            for si in doc.descendants().filter(|n| n.has_tag_name("si")) {
                let text: String = si
                    .descendants()
                    .filter(|n| n.has_tag_name("t"))
                    .filter_map(|n| n.text())
                    .collect();
                shared.push(text);
            }
        }
    }
    let mut sheet_names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_owned()))
        .filter(|n| n.starts_with("xl/worksheets/sheet") && n.ends_with(".xml"))
        .collect();
    sheet_names.sort();
    sheet_names.truncate(MAX_SHEETS_OR_SLIDES);

    let mut sections = Vec::new();
    for sheet_name in sheet_names {
        let Ok(xml) = read_zip_entry(&mut archive, &sheet_name) else {
            continue;
        };
        let Ok(doc) = roxmltree::Document::parse(&xml) else {
            continue;
        };
        let mut rows = Vec::new();
        for row in doc.descendants().filter(|n| n.has_tag_name("row")) {
            let mut cells = Vec::new();
            for cell in row.children().filter(|n| n.has_tag_name("c")) {
                let kind = cell.attribute("t").unwrap_or("");
                let val = if kind == "s" {
                    cell.children()
                        .find(|n| n.has_tag_name("v"))
                        .and_then(|v| v.text())
                        .and_then(|s| s.parse::<usize>().ok())
                        .and_then(|idx| shared.get(idx))
                        .cloned()
                        .unwrap_or_default()
                } else if kind == "inlineStr" {
                    cell.descendants()
                        .filter(|n| n.has_tag_name("t"))
                        .filter_map(|n| n.text())
                        .collect()
                } else {
                    cell.children()
                        .find(|n| n.has_tag_name("v"))
                        .and_then(|v| v.text())
                        .unwrap_or("")
                        .to_owned()
                };
                if !val.is_empty() {
                    cells.push(val);
                }
            }
            if !cells.is_empty() {
                rows.push(cells.join("\t"));
            }
        }
        if !rows.is_empty() {
            sections.push(rows.join("\n"));
        }
    }
    Ok(sections.join("\n\n"))
}

fn extract_pptx(bytes: &[u8]) -> Result<String, String> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| "UnsupportedFormat".to_string())?;
    let mut slide_names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_owned()))
        .filter(|n| n.starts_with("ppt/slides/slide") && n.ends_with(".xml"))
        .collect();
    slide_names.sort();
    slide_names.truncate(MAX_SHEETS_OR_SLIDES);

    let mut slides = Vec::new();
    for slide_name in slide_names {
        let Ok(xml) = read_zip_entry(&mut archive, &slide_name) else {
            continue;
        };
        let Ok(doc) = roxmltree::Document::parse(&xml) else {
            continue;
        };
        let mut lines = Vec::new();
        for p in doc.descendants().filter(|n| n.has_tag_name("p")) {
            let line: String = p
                .descendants()
                .filter(|n| n.has_tag_name("t"))
                .filter_map(|n| n.text())
                .collect();
            if !line.trim().is_empty() {
                lines.push(line);
            }
        }
        if !lines.is_empty() {
            slides.push(lines.join("\n"));
        }
    }
    Ok(slides.join("\n\n"))
}

#[cfg(target_os = "macos")]
fn extract_pdf(bytes: &[u8]) -> Result<String, String> {
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2_foundation::{NSData, NSString};
    use std::sync::Once;

    static LOAD_PDFKIT: Once = Once::new();
    LOAD_PDFKIT.call_once(|| unsafe {
        let path = c"/System/Library/Frameworks/PDFKit.framework/PDFKit";
        let _ = libc::dlopen(path.as_ptr(), libc::RTLD_LAZY | libc::RTLD_GLOBAL);
    });

    if let Some(cls) = AnyClass::get(c"PDFDocument") {
        let data = NSData::with_bytes(bytes);
        unsafe {
            let alloc: *mut AnyObject = msg_send![cls, alloc];
            let raw_doc: *mut AnyObject = msg_send![alloc, initWithData: &*data];
            if let Some(doc) = Retained::from_raw(raw_doc) {
                let text: Option<Retained<NSString>> = msg_send![&*doc, string];
                if let Some(s) = text {
                    let extracted = s.to_string();
                    if !extracted.trim().is_empty() {
                        return Ok(extracted);
                    }
                }
                return Ok(String::new());
            }
        }
    }
    extract_pdf_fallback(bytes)
}

#[cfg(not(target_os = "macos"))]
fn extract_pdf(bytes: &[u8]) -> Result<String, String> {
    extract_pdf_fallback(bytes)
}

/// Minimal fallback extractor for simple uncompressed PDF literal strings `(...) Tj`.
fn extract_pdf_fallback(bytes: &[u8]) -> Result<String, String> {
    if !bytes.starts_with(b"%PDF-") {
        return Err("UnsupportedFormat".into());
    }
    let text = String::from_utf8_lossy(bytes);
    let mut out = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '(' {
            let mut s = String::new();
            let mut depth = 1usize;
            while let Some(c) = chars.next() {
                if c == '\\' {
                    if let Some(esc) = chars.next() {
                        s.push(match esc {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            other => other,
                        });
                    }
                } else if c == '(' {
                    depth += 1;
                    s.push(c);
                } else if c == ')' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                    s.push(c);
                } else {
                    s.push(c);
                }
            }
            if s.chars().any(|c| c.is_alphanumeric()) {
                out.push(s);
            }
        }
    }
    Ok(out.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn detects_common_asset_mimes() {
        assert_eq!(detect_mime("report.pdf", b"%PDF-1.7"), "application/pdf");
        assert_eq!(
            detect_mime("resume.docx", b"PK\x03\x04"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        );
        assert_eq!(
            detect_mime("model.xlsx", b"PK\x03\x04"),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        );
        assert_eq!(detect_mime("shot.png", b"\x89PNG\r\n\x1a\n"), "image/png");
    }

    #[test]
    fn extracts_docx_and_xlsx_locally() {
        // Build minimal synthetic DOCX zip
        let mut docx_buf = Cursor::new(Vec::new());
        {
            let mut zw = zip::ZipWriter::new(&mut docx_buf);
            zw.start_file(
                "word/document.xml",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
            zw.write_all(
                r#"<?xml version="1.0" encoding="UTF-8"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body>
                    <w:p><w:r><w:t>架构师简历</w:t></w:r></w:p>
                    <w:p><w:r><w:t>2026 年度项目复盘</w:t></w:r></w:p>
                  </w:body>
                </w:document>"#
                    .as_bytes(),
            )
            .unwrap();
            zw.finish().unwrap();
        }
        let docx_text = extract_text("resume.docx", "", docx_buf.get_ref()).unwrap();
        assert!(docx_text.contains("架构师简历"));
        assert!(docx_text.contains("2026 年度项目复盘"));

        // Build minimal synthetic XLSX zip
        let mut xlsx_buf = Cursor::new(Vec::new());
        {
            let mut zw = zip::ZipWriter::new(&mut xlsx_buf);
            zw.start_file(
                "xl/sharedStrings.xml",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
            zw.write_all(br#"<sst><si><t>VOO</t></si><si><t>QQQM</t></si></sst>"#)
                .unwrap();
            zw.start_file(
                "xl/worksheets/sheet1.xml",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
            zw.write_all(
                br#"<worksheet><sheetData>
                    <row><c t="s"><v>0</v></c><c><v>85</v></c></row>
                    <row><c t="s"><v>1</v></c><c><v>120</v></c></row>
                </sheetData></worksheet>"#,
            )
            .unwrap();
            zw.finish().unwrap();
        }
        let xlsx_text = extract_text("portfolio.xlsx", "", xlsx_buf.get_ref()).unwrap();
        assert!(xlsx_text.contains("VOO\t85"));
        assert!(xlsx_text.contains("QQQM\t120"));
    }
}
