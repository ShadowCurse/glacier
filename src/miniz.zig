const miniz = @cImport({
    @cDefine("MINIZ_NO_STDIO", "");
    @cDefine("MINIZ_NO_MALLOC", "");
    @cDefine("MINIZ_NO_ARCHIVE_APIS", "");
    @cDefine("MINIZ_NO_DEFLATE_APIS", "");
    @cDefine("MINIZ_LITTLE_ENDIAN", "1");
    @cDefine("MINIZ_HAS_64BIT_REGISTERS", "1");
    @cInclude("miniz.h");
});

pub usingnamespace miniz;
