# -*- coding: utf-8 -*-
"""115 小文件直传（sampleinitupload → OSS multipart）。

用于字幕等小文件；大文件应走秒传/分片接口（此处不做）。
"""


import logging


import app.p115.client as p115_client
log = logging.getLogger(__name__)

SAMPLE_INIT = "https://uplb.115.com/3.0/sampleinitupload.php"
MAX_SAMPLE_BYTES = 20 * 1024 * 1024


