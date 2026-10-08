function Initialize-FolderSizeNative {
	# The worker runspace cannot see script functions. This type is loaded once
	# into the process so both runspaces can call it. Re-dot-sourcing this file
	# must not define the type again.
	if ('FolderSizeNative' -as [type]) { return }

	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FolderSizeNative {
	const uint FileReadAttributes = 0x80;
	const uint OpenExisting = 3;
	const uint OpenReparse = 0x00200000;
	const uint BackupSemantics = 0x02000000;
	const uint OpenNoRecall = 0x00100000;
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
			throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
		return ((ulong)high << 32) | low;
	}

	public static bool IsSymlinkOrJunction(string path) {
		IntPtr handle = CreateFileW(
			path,
			FileReadAttributes,
			7,
			IntPtr.Zero,
			OpenExisting,
			OpenReparse | BackupSemantics | OpenNoRecall,
			IntPtr.Zero);
		if (handle == new IntPtr(-1)) return false;
		try {
			AttributeTagInfo info;
			int size = Marshal.SizeOf(typeof(AttributeTagInfo));
			if (!GetFileInformationByHandleEx(handle, 9, out info, (uint)size)) return false;
			return info.ReparseTag == SymlinkTag || info.ReparseTag == MountPointTag;
		}
		finally {
			CloseHandle(handle);
		}
	}
}
'@
}
