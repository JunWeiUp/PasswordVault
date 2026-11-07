//! Bounded AF_UNIX connect, shared by startup probes and the MCP adapter.
use std::{io, os::unix::net::UnixStream, path::Path, time::Duration};
pub fn connect_timeout(path: &Path, timeout: Duration) -> io::Result<UnixStream> {
    if timeout.is_zero() {
        return Err(io::ErrorKind::TimedOut.into());
    }
    let socket = socket2::Socket::new(socket2::Domain::UNIX, socket2::Type::STREAM, None)?;
    // socket2 sets CLOEXEC and connects nonblocking, then polls with a deadline.
    // CLOEXEC alone cannot prevent a brief inherited-fd window before exec.
    socket.connect_timeout(&socket2::SockAddr::unix(path)?, timeout)?;
    Ok(socket.into())
}
