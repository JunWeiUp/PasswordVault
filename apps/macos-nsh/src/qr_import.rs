//! Local, bounded QR image decoding. Images are never uploaded.
use nsh_core::prelude::*;
/// Local authenticator image importer.
#[module]
pub struct QrImport;

fn decode(path: &std::path::Path) -> Result<String, String> {
    if std::fs::metadata(path).map_err(|_| "Cannot read image")?.len() > 20 * 1024 * 1024 {
        return Err("Image exceeds 20 MB".into());
    }
    let bytes = std::fs::read(path).map_err(|_| "Cannot read image")?;
    decode_bytes(&bytes, "otpauth://")
}
pub(crate) fn decode_bytes(bytes: &[u8], scheme: &str) -> Result<String, String> {
    if bytes.len() > 20 * 1024 * 1024 { return Err("Image exceeds 20 MB".into()); }
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format().map_err(|_| "Unsupported image")?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().map_err(|_| "Invalid or oversized image")?.to_luma8();
    let mut prepared = rqrr::PreparedImage::prepare(image);
    let mut values = Vec::new();
    for grid in prepared.detect_grids() {
        if let Ok((_, value)) = grid.decode() {
            if value.starts_with(scheme) && !values.contains(&value) { values.push(value); }
        }
    }
    if values.len() != 1 { return Err("Select an image containing exactly one matching QR code".into()); }
    Ok(values.remove(0))
}
#[module]
impl QrImport {
    /// Decodes exactly one authenticator URI from a bounded local image.
    pub async fn from_image(path: String) -> Result<String, String> {
        blocking(move || decode(std::path::Path::new(&path))).await.map_err(|_| "Image decoder failed".to_string())?
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relay_images_are_bounded_and_do_not_accept_totp() {
        let value = "common-relay://relay.example.test/i/example#key";
        let code = qrcode::QrCode::new(value).unwrap();
        let side = (code.width() + 8) * 8;
        let mut image = image::GrayImage::from_pixel(side as u32, side as u32, image::Luma([255]));
        for y in 0..code.width() { for x in 0..code.width() {
            if code[(x,y)] == qrcode::Color::Dark { for dy in 0..8 { for dx in 0..8 {
                image.put_pixel(((x+4)*8+dx) as u32, ((y+4)*8+dy) as u32, image::Luma([0]));
            } } }
        } }
        let mut encoded = std::io::Cursor::new(Vec::new());
        image.write_to(&mut encoded, image::ImageFormat::Png).unwrap();
        assert_eq!(decode_bytes(encoded.get_ref(), "common-relay://").unwrap(), value);
        assert!(decode_bytes(encoded.get_ref(), "otpauth://").is_err());
        assert!(decode_bytes(b"not an image", "common-relay://").is_err());
        assert!(decode_bytes(&vec![0; 20 * 1024 * 1024 + 1], "common-relay://").is_err());
    }
    #[test]
    fn decodes_generated_fixture_and_rejects_non_authenticator() {
        let dir = std::env::temp_dir().join(format!("pv-qr-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("fixture.png");
        for value in ["otpauth://totp/Test:qa?secret=JBSWY3DPEHPK3PXP", "https://example.test"] {
            let code = qrcode::QrCode::new(value).unwrap();
            let side = (code.width() + 8) * 8;
            let mut image = image::GrayImage::from_pixel(side as u32, side as u32, image::Luma([255]));
            for y in 0..code.width() { for x in 0..code.width() {
                if code[(x,y)] == qrcode::Color::Dark { for dy in 0..8 { for dx in 0..8 {
                    image.put_pixel(((x+4)*8+dx) as u32, ((y+4)*8+dy) as u32, image::Luma([0]));
                } } }
            } }
            image.save(&path).unwrap();
            let result = decode(&path);
            if value.starts_with("otpauth:") { assert_eq!(result.unwrap(), value); } else { assert!(result.is_err()); }
        }
        std::fs::write(&path, b"not an image").unwrap();
        assert!(decode(&path).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
