// Windows compatibility for the Programmable Launch CLI, loaded with:
//   node --import ./programmable/win-dir-fsync-shim.mjs <path-to>/programmable-launch.mjs ...
// The CLI fsyncs the directory after an atomic rename (POSIX durability). Windows refuses fsync on a
// directory handle with EPERM. This shim ignores exactly that case; file fsyncs and every other error
// are untouched, and no CLI byte is modified. Not needed on Linux or macOS.
import { open } from "node:fs/promises";

if (process.platform === "win32") {
  const probe = await open(process.execPath, "r");
  const FileHandle = Object.getPrototypeOf(probe);
  await probe.close();
  const originalSync = FileHandle.sync;
  FileHandle.sync = async function sync() {
    try {
      return await originalSync.call(this);
    } catch (error) {
      if (error?.code === "EPERM" && (await this.stat()).isDirectory()) return undefined;
      throw error;
    }
  };
}
