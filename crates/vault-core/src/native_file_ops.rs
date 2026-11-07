//! Native filesystem persistence shared with desktop clients.
use std::{io, path::Path};

/// POSIX directories can be fsynced. Windows does not expose that operation;
/// file contents are flushed before write-through rename instead. NTFS deletion
/// metadata still relies on filesystem journaling; no power-loss guarantee is made.
pub fn sync_directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        std::fs::File::open(path)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

/// Replace an encrypted journal record after its contents have been synced.
/// Windows cannot fsync directories through std::fs::File::open.
pub fn replace_synced(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileAttributesW, MoveFileExW, SetFileAttributesW, FILE_ATTRIBUTE_NORMAL,
            FILE_ATTRIBUTE_TEMPORARY, INVALID_FILE_ATTRIBUTES, MOVEFILE_REPLACE_EXISTING,
            MOVEFILE_WRITE_THROUGH,
        };
        let wide = |path: &Path| -> io::Result<Vec<u16>> {
            let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
            if value.contains(&0) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"));
            }
            value.push(0);
            Ok(value)
        };
        let source = wide(source)?;
        let destination = wide(destination)?;
        // NamedTempFile marks Windows files TEMPORARY. Clear that hint before
        // persistence, retaining other attributes (including directory flags).
        let attributes = unsafe { GetFileAttributesW(source.as_ptr()) };
        if attributes == INVALID_FILE_ATTRIBUTES {
            return Err(io::Error::last_os_error());
        }
        if attributes & FILE_ATTRIBUTE_TEMPORARY != 0 {
            let persistent = attributes & !FILE_ATTRIBUTE_TEMPORARY;
            let persistent = if persistent == 0 {
                FILE_ATTRIBUTE_NORMAL
            } else {
                persistent
            };
            if unsafe { SetFileAttributesW(source.as_ptr(), persistent) } == 0 {
                return Err(io::Error::last_os_error());
            }
        }
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            let error = io::Error::last_os_error();
            if attributes & FILE_ATTRIBUTE_TEMPORARY != 0 {
                unsafe {
                    SetFileAttributesW(source.as_ptr(), attributes);
                }
            }
            return Err(error);
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        std::fs::rename(source, destination)?;
        sync_directory(
            destination
                .parent()
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing parent"))?,
        )
    }
}
