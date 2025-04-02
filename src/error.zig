pub const Error = error{
    GracefulShutdown,
    OutOfMemory,
    Unexpected,
    ExeNotFound,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
    AlreadyExists,
    DeleteDirFailure,
    DeleteFileFailure,
    RestoreFailure,
};
