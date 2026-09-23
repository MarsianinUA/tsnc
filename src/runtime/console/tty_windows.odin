package console

import "core:os"
import win "core:sys/windows"

// is_console answers what libuv does for a Windows stream: a character device that GetConsoleMode
// accepts, which NUL is not. It runs at every console.log, and GetConsoleMode of a file or a pipe
// costs about five times what GetFileType does, so GetFileType answers for those.
@(private)
is_console :: proc(stream: Stream) -> bool {
	handle := win.HANDLE(os.fd(file_of(stream)))
	if win.GetFileType(handle) != win.FILE_TYPE_CHAR {
		return false
	}
	mode: win.DWORD
	return bool(win.GetConsoleMode(handle, &mode))
}

// enable_console_escapes turns on the processing of escape sequences in a console that lacks it,
// as libuv does for a TTY stream, and like libuv never turns it off. A pipe or a file is left alone.
@(private)
enable_console_escapes :: proc(stream: Stream) {
	handle := win.HANDLE(os.fd(file_of(stream)))
	mode: win.DWORD
	if win.GetConsoleMode(handle, &mode) && mode & win.ENABLE_VIRTUAL_TERMINAL_PROCESSING == 0 {
		win.SetConsoleMode(handle, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
	}
}
