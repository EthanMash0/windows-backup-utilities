function Initialize-FolderSizeNative {
	# The worker runspace cannot see script functions. This type is loaded once
	# into the process so both runspaces can call it. Re-dot-sourcing this file
	# must not define the type again.
	$loaded = 'FolderSizeNative' -as [type]
	if ($null -ne $loaded) {
		if ($null -eq $loaded.GetMethod('ReparseTag')) {
			throw 'An older version of the folder size tool is loaded in this PowerShell window. Close it and start the tool again.'
		}
		return
	}

	Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class FolderSizeNative {
	const uint FileReadAttributes = 0x80;
	const uint OpenExisting = 3;
	const uint OpenReparse = 0x00200000;
	const uint BackupSemantics = 0x02000000;
	const uint OpenNoRecall = 0x00100000;
	const int FileAttributeTagInfoClass = 9;
	const uint SymlinkTag = 0xA000000C;
	const uint MountPointTag = 0xA0000003;

	[StructLayout(LayoutKind.Sequential)]
	struct AttributeTagInfo {
		public uint FileAttributes;
		public uint ReparseTag;
	}

	[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
	static extern uint GetCompressedFileSizeW(string path, out uint high);

	[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
	static extern IntPtr CreateFileW(
		string name,
		uint access,
		uint share,
		IntPtr security,
		uint disposition,
		uint flags,
		IntPtr templateFile);

	[DllImport("kernel32.dll", SetLastError = true)]
	static extern bool GetFileInformationByHandleEx(
		IntPtr handle,
		int fileInformationClass,
		out AttributeTagInfo info,
		uint bufferSize);

	[DllImport("kernel32.dll", SetLastError = true)]
	static extern bool CloseHandle(IntPtr handle);

	public static ulong StoredSize(string path) {
		uint high;
		uint low = GetCompressedFileSizeW(path, out high);
		if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0)
			throw new Win32Exception(Marshal.GetLastWin32Error());
		return ((ulong)high << 32) | low;
	}

	// Opens the reparse point itself, not its target, and does not recall a
	// cloud placeholder. Throws when the item cannot be opened.
	public static uint ReparseTag(string path) {
		IntPtr handle = CreateFileW(
			path,
			FileReadAttributes,
			7,
			IntPtr.Zero,
			OpenExisting,
			OpenReparse | BackupSemantics | OpenNoRecall,
			IntPtr.Zero);
		if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
		try {
			AttributeTagInfo info;
			int size = Marshal.SizeOf(typeof(AttributeTagInfo));
			if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfoClass, out info, (uint)size))
				throw new Win32Exception(Marshal.GetLastWin32Error());
			return info.ReparseTag;
		}
		finally {
			CloseHandle(handle);
		}
	}

	// Robocopy /XJ does not follow these. Every other tag, such as a cloud
	// placeholder, is walked or measured like an ordinary item.
	public static string SkippedReparseKind(uint tag) {
		if (tag == SymlinkTag) return "symlink";
		if (tag == MountPointTag) return "junction or mount point";
		return null;
	}
}
'@
}
