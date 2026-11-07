//! Handle-based validation shared by native document imports.
use std::{fs::{File, OpenOptions}, io, path::Path};

pub(crate) fn open_regular_readonly(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::path::{Component, Prefix};
        // Reject device namespaces and named-pipe shares before opening a handle:
        // a blocking pipe must never enter the ordinary-document import path.
        let disk_path = path.is_absolute() && match path.components().next() {
            Some(Component::Prefix(prefix)) => match prefix.kind() {
                Prefix::Disk(_) | Prefix::VerbatimDisk(_) => true,
                Prefix::UNC(server, share) | Prefix::VerbatimUNC(server, share) => {
                    !matches!(server.to_str(), Some(".") | Some("?"))
                        && !share.to_string_lossy().eq_ignore_ascii_case("pipe")
                        && !share.to_string_lossy().eq_ignore_ascii_case("ipc$")
                }
                _ => false,
            },
            _ => false,
        };
        if !disk_path { return Err(io::Error::new(io::ErrorKind::InvalidInput, "Not a disk file path")); }
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT: inspect the link itself, not its target.
        // Disallow concurrent writes/deletes while the imported file is open.
        options.custom_flags(0x00200000).share_mode(1);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // FILE_ATTRIBUTE_REPARSE_POINT includes junctions and other redirections.
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "Reparse point"));
        }
    }
    if !metadata.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Not a regular file"));
    }
    Ok(file)
}

pub(crate) use vault_core::native_file_ops::replace_synced;

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn rejects_device_and_remote_pipe_namespaces_before_opening() {
        for path in [r"\\.\pipe\passwordvault-test", r"\\localhost\pipe\passwordvault-test", r"\\server\IPC$\test", r"\\?\GLOBALROOT\Device\NamedPipe\test", "NUL"] {
            assert_eq!(open_regular_readonly(Path::new(path)).unwrap_err().kind(), io::ErrorKind::InvalidInput);
        }
    }
    #[test]
    fn replacement_preserves_destination_on_missing_source() {
        let directory = std::env::temp_dir().join(format!("pv-replace-check-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let target = directory.join("target");
        let source = directory.join("staging");
        std::fs::write(&target, b"old").unwrap();
        assert!(replace_synced(&source, &target).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"old");
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(windows)] {
            use std::os::windows::fs::OpenOptionsExt;
            options.attributes(windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_TEMPORARY);
        }
        let mut staging = options.open(&source).unwrap();
        std::io::Write::write_all(&mut staging, b"new").unwrap();
        staging.sync_all().unwrap();
        drop(staging);
        replace_synced(&source, &target).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!source.exists());
        #[cfg(windows)] {
            use std::os::windows::fs::MetadataExt;
            assert_eq!(std::fs::metadata(&target).unwrap().file_attributes() & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_TEMPORARY, 0);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn accepts_file_rejects_directory_and_missing_path() {
        let directory = std::env::temp_dir().join(format!("pv-file-check-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("synthetic.txt");
        std::fs::write(&path, "synthetic data").unwrap();
        assert!(open_regular_readonly(&path).is_ok());
        assert!(open_regular_readonly(&directory).is_err());
        assert!(open_regular_readonly(&directory.join("missing")).is_err());
        #[cfg(unix)]
        {
            let link = directory.join("link");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(open_regular_readonly(&link).is_err());
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
