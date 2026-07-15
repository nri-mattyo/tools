# here are some recent runs of the command

```shell
## Usage

```bash
buckets=(
 s3://aws-cloudtrail-logs-381492092437-74dbd159/AWSLogs/381492092437/CloudTrail/           # --from-profile nri-develop
 s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/    # --from-profile nri-develop
 s3://nri-cloudtrail-logs-637423466983/cloudtrail-logs/AWSLogs/637423466983/CloudTrail/    # --from-profile nri-customer
 s3://aws-cloudtrail-logs-293034550673-c21dd2f3/AWSLogs/293034550673/CloudTrail/           # --from-profile newton
)
DATE=2026/06/
function update_batches() {
  CT_DEV_A=(
   --from "s3://aws-cloudtrail-logs-381492092437-74dbd159/AWSLogs/381492092437/CloudTrail/*/${DATE}"
   --from-profile nri-develop
   --to   "s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/"
   --to-profile nri-develop
  )
  CT_DEV_B=(
   --from "s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/${DATE}"
   --from-profile nri-develop
   --to   "s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/"
   --to-profile nri-develop
  )
  CT_CUST_A=(
   --from "s3://nri-cloudtrail-logs-637423466983/cloudtrail-logs/AWSLogs/637423466983/CloudTrail/*/${DATE}"
   --from-profile nri-customer
   --to   "s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/"
   --to-profile nri-develop
  )
  CT_NEWTON_A=(
   --from "s3://aws-cloudtrail-logs-293034550673-c21dd2f3/AWSLogs/293034550673/CloudTrail/*/${DATE}"
   --from-profile newton
   --to   "s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/"
   --to-profile nri-develop
  )
}
python cli.py consolidate "${CT_DEV_A[@]}" --progress --workers 64
python cli.py consolidate "${CT_DEV_B[@]}" --progress --workers 64
python cli.py consolidate "${CT_CUST_A[@]}" --progress --workers 64
#2026-07-03 13:08:27,950 INFO convert: summary: files_processed=5080 files_skipped=0 bytes_processed=407367163 lines_processed=2223328 elapsed_sec=632.5 avg_bytes_per_sec=644079 avg_lines_per_sec=3515
#2026-07-03 13:08:27,978 INFO cli: done: 5080 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
# with threading default options
#2026-07-03 13:42:53,251 INFO convert: summary: files_processed=10684 files_skipped=0 bytes_processed=463283134 lines_processed=2474273 elapsed_sec=185.4 avg_bytes_per_sec=2498220 avg_lines_per_sec=13342
#2026-07-03 13:42:53,297 INFO cli: done: 10684 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
# 24 workers on nri-customer data
#2026-07-03 14:01:48,331 INFO convert: summary: files_processed=3350 files_skipped=0 bytes_processed=295350207 lines_processed=1642075 elapsed_sec=95.9 avg_bytes_per_sec=3079543 avg_lines_per_sec=17122
#2026-07-03 14:01:48,360 INFO cli: done: 3350 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
# 32 workers
#2026-07-03 14:05:40,772 INFO convert: summary: files_processed=9938 files_skipped=0 bytes_processed=502223742 lines_processed=2888691 elapsed_sec=162.8 avg_bytes_per_sec=3085788 avg_lines_per_sec=17749
#2026-07-03 14:05:40,847 INFO cli: done: 9938 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
# 64 workers had a cpu spike on 6 cores but seems it is not using all cores (python cli.py consolidate "${CT_DEV_A[@]}" --progress --workers 64)
#2026-07-03 14:09:45,488 INFO convert: summary: files_processed=16070 files_skipped=0 bytes_processed=481798664 lines_processed=2835360 elapsed_sec=173.5 avg_bytes_per_sec=2777669 avg_lines_per_sec=16346
#2026-07-03 14:09:45,523 INFO cli: done: 16070 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
# time echo $DATE && python cli.py consolidate "${CT_NEWTON_A[@]}" --progress --workers 32
#2026-07-03 14:17:01,172 INFO convert: summary: files_processed=38363 files_skipped=748 bytes_processed=76641174 lines_processed=272644 elapsed_sec=210.5 avg_bytes_per_sec=364137 avg_lines_per_sec=1295
#2026-07-03 14:17:01,251 INFO cli: done: 38363 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

# python cli.py consolidate "${CT_DEV_A[@]}" --progress --workers 64
#2026-07-03 14:38:30,715 INFO convert: summary: files_processed=34183 files_skipped=16070 bytes_processed=2662490275 lines_processed=13738561 elapsed_sec=1057.5 avg_bytes_per_sec=2517825 avg_lines_per_sec=12992
#2026-07-03 14:38:30,779 INFO cli: done: 34183 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
time echo $DATE && python cli.py consolidate "${CT_DEV_B[@]}" --progress --workers 64
#2026/06/
#2026-07-03 14:40:30,615 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 14:40:30,972 INFO botocore.tokens: SSO Token refresh succeeded
#2026-07-03 14:40:31,861 INFO convert: resolved 17 source prefix(es) under s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/06/
#2026-07-03 14:40:54,712 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 14:40:57,883 INFO convert: 99965/99965 source files are new (unprocessed)
#2026-07-03 14:53:34,902 INFO convert: wrote 201082 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
#2026-07-03 14:53:39,646 INFO convert: progress: files_processed=56913 files_skipped=0 bytes_processed=1676234422 lines_processed=8843937 bytes_per_sec=2124410 lines_per_sec=11209
#2026-07-03 14:53:45,310 INFO convert: progress: files_processed=57371 files_skipped=0 bytes_processed=1722027540 lines_processed=8992724 bytes_per_sec=2166893 lines_per_sec=11316
#2026-07-03 14:53:55,952 INFO convert: wrote 200066 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
#2026-07-03 14:54:00,924 INFO convert: progress: files_processed=57554 files_skipped=0 bytes_processed=1733931147 lines_processed=9044097 bytes_per_sec=2139828 lines_per_sec=11161
#2026-07-03 14:54:06,157 INFO convert: progress: files_processed=58369 files_skipped=0 bytes_processed=1763392252 lines_processed=9181887 bytes_per_sec=2162222 lines_per_sec=11259
time echo $DATE && python cli.py consolidate "${CT_DEV_B[@]}" --progress --workers 64 --chunk-by date
#2026/06/
#2026-07-03 14:54:22,623 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 14:54:23,468 INFO convert: resolved 17 source prefix(es) under s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/06/
#2026-07-03 14:54:44,970 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 14:54:49,526 INFO convert: 42412/99965 source files are new (unprocessed)
#2026-07-03 15:10:38,224 INFO convert: wrote 204463 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
#2026-07-03 15:10:46,828 INFO convert: progress: files_processed=27919 files_skipped=57553 bytes_processed=2011202797 lines_processed=9971812 bytes_per_sec=2043396 lines_per_sec=10131
#2026-07-03 15:10:53,320 INFO convert: progress: files_processed=28259 files_skipped=57553 bytes_processed=2039351553 lines_processed=10088803 bytes_per_sec=2058417 lines_per_sec=10183
#2026-07-03 15:11:04,175 INFO convert: wrote 203159 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/
#2026-07-03 15:11:11,957 INFO convert: progress: files_processed=28487 files_skipped=57553 bytes_processed=2057668177 lines_processed=10175319 bytes_per_sec=2038558 lines_per_sec=10081
#2026-07-03 15:11:17,193 INFO convert: progress: files_processed=28902 files_skipped=57553 bytes_processed=2089364757 lines_processed=10355224 bytes_per_sec=2059278 lines_per_sec=10206
time echo $DATE && python cli.py consolidate "${CT_DEV_B[@]}" --progress --workers 64 --chunk-by date
#2026/06/
#2026-07-03 15:12:03,353 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 15:12:04,294 INFO convert: resolved 17 source prefix(es) under s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/06/
#2026-07-03 15:12:25,621 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 15:12:31,378 INFO convert: 13459/99965 source files are new (unprocessed)
#2026-07-03 15:16:29,892 INFO convert: progress: files_processed=13067 files_skipped=86506 bytes_processed=542709723 lines_processed=2952378 bytes_per_sec=2275418 lines_per_sec=12378
#2026-07-03 15:16:37,267 INFO convert: progress: files_processed=13252 files_skipped=86506 bytes_processed=559786585 lines_processed=3021902 bytes_per_sec=2276615 lines_per_sec=12290
#2026-07-03 15:16:45,258 INFO convert: wrote 200420 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (6.9s, 28874 rows/s)
#2026-07-03 15:16:54,419 INFO convert: wrote 53686 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (1.6s, 34160 rows/s)
#2026-07-03 15:17:04,119 INFO convert: summary: files_processed=13459 files_skipped=86506 bytes_processed=568661196 lines_processed=3075514 elapsed_sec=272.7 avg_bytes_per_sec=2085014 avg_lines_per_sec=11276
#2026-07-03 15:17:04,198 INFO cli: done: 13459 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

time echo $DATE && python cli.py consolidate "${CT_CUST_A[@]}" --progress --workers 64
#2026/06/
#2026-07-03 15:18:22,237 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 15:18:23,121 INFO convert: resolved 18 source prefix(es) under s3://nri-cloudtrail-logs-637423466983/cloudtrail-logs/AWSLogs/637423466983/CloudTrail/*/2026/06/
#2026-07-03 15:18:31,472 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 15:18:36,773 INFO convert: 23988/33926 source files are new (unprocessed)
#2026-07-03 15:18:41,838 INFO convert: progress: files_processed=3075 files_skipped=9938 bytes_processed=8855099 lines_processed=31578 bytes_per_sec=1748149 lines_per_sec=6234
#2026-07-03 15:27:39,213 INFO convert: wrote 200288 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (8.4s, 23970 rows/s)
#2026-07-03 15:27:45,504 INFO convert: progress: files_processed=17764 files_skipped=9938 bytes_processed=1245952566 lines_processed=6622206 bytes_per_sec=2270450 lines_per_sec=12067
#2026-07-03 15:27:50,774 INFO convert: progress: files_processed=17924 files_skipped=9938 bytes_processed=1260048958 lines_processed=6698344 bytes_per_sec=2274296 lines_per_sec=12090
#2026-07-03 15:27:56,522 INFO convert: wrote 201158 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (10.0s, 20175 rows/s)
#2026-07-03 15:27:56,781 INFO convert: progress: files_processed=18012 files_skipped=9938 bytes_processed=1267689577 lines_processed=6738711 bytes_per_sec=2263544 lines_per_sec=12032
#2026-07-03 15:28:03,729 INFO convert: progress: files_processed=18136 files_skipped=9938 bytes_processed=1282991569 lines_processed=6822179 bytes_per_sec=2262791 lines_per_sec=12032
#^C2026-07-03 15:28:10,746 INFO convert: wrote 200084 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (6.0s, 33252 rows/s)
#2026-07-03 15:33:13,626 INFO convert: summary: files_processed=6225 files_skipped=27701 bytes_processed=603569548 lines_processed=3267819 elapsed_sec=278.4 avg_bytes_per_sec=2168353 avg_lines_per_sec=11740
#2026-07-03 15:33:13,689 INFO cli: done: 6225 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

> time echo $DATE && python cli.py consolidate "${CT_DEV_A[@]}" --progress --workers 64
#2026/0
#2026-07-03 20:50:46,018 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 20:50:46,920 INFO convert: resolved 17 source prefix(es) under s3://aws-cloudtrail-logs-381492092437-74dbd159/AWSLogs/381492092437/CloudTrail/*/2026/0
#2026-07-03 20:51:42,606 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-03 20:51:46,899 INFO convert: 246059/301442 source files are new (unprocessed)
#2026-07-03 20:51:51,923 INFO convert: progress: files_processed=2348 files_skipped=55383 bytes_processed=9428528 lines_processed=71990 bytes_per_sec=1876580 lines_per_sec=14328
#2026-07-03 20:51:56,924 INFO convert: progress: files_processed=4796 files_skipped=55383 bytes_processed=18881101 lines_processed=143728 bytes_per_sec=1883447 lines_per_sec=14337
#2026-07-03 20:52:02,243 INFO convert: progress: files_processed=6370 files_skipped=55383 bytes_processed=37278934 lines_processed=268774 bytes_per_sec=2429536 lines_per_sec=17516
#2026-07-03 20:52:32,752 INFO convert: wrote 200200 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (32.8s, 6106 rows/s)
#2026-07-03 21:54:08,264 INFO convert: progress: files_processed=243903 files_skipped=55383 bytes_processed=3766515765 lines_processed=24307611 bytes_per_sec=1006739 lines_per_sec=6497
#2026-07-03 21:54:13,274 INFO convert: progress: files_processed=245960 files_skipped=55383 bytes_processed=3772815640 lines_processed=24344906 bytes_per_sec=1007074 lines_per_sec=6498
#2026-07-03 21:54:32,890 INFO convert: wrote 200000 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (23.8s, 8388 rows/s)
#2026-07-03 21:55:16,323 INFO convert: wrote 40981 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (20.4s, 2011 rows/s)
#2026-07-03 21:55:37,755 INFO convert: summary: files_processed=246059 files_skipped=55383 bytes_processed=3773250397 lines_processed=24348589 elapsed_sec=3830.8 avg_bytes_per_sec=984979 avg_lines_per_sec=6356
#2026-07-03 21:55:37,908 INFO cli: done: 246059 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

> time echo $DATE && python cli.py consolidate "${CT_DEV_B[@]}" --progress --workers 64
#2026/0
#2026-07-04 00:27:56,503 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 00:27:57,064 INFO botocore.tokens: SSO Token refresh succeeded
#2026-07-04 00:27:58,019 INFO convert: resolved 17 source prefix(es) under s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/0
#2026-07-04 00:29:43,350 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 00:29:54,382 INFO convert: 449168/559817 source files are new (unprocessed)
#2026-07-04 00:29:59,395 INFO convert: progress: files_processed=2791 files_skipped=110649 bytes_processed=10412353 lines_processed=78040 bytes_per_sec=2076947 lines_per_sec=15567
#2026-07-04 00:30:04,420 INFO convert: progress: files_processed=5186 files_skipped=110649 bytes_processed=20496234 lines_processed=156354 bytes_per_sec=2041765 lines_per_sec=15575
#2026-07-04 00:30:09,488 INFO convert: progress: files_processed=6167 files_skipped=110649 bytes_processed=40861496 lines_processed=279927 bytes_per_sec=2704835 lines_per_sec=18530
#2026-07-04 00:30:31,809 INFO convert: wrote 201267 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (25.2s, 7982 rows/s)
#2026-07-04 00:30:45,385 INFO convert: progress: files_processed=8059 files_skipped=110649 bytes_processed=62066154 lines_processed=401815 bytes_per_sec=1216861 lines_per_sec=7878
#2026-07-04 00:30:50,399 INFO convert: progress: files_processed=8622 files_skipped=110649 bytes_processed=68965659 lines_processed=447791 bytes_per_sec=1231
#2026-07-04 03:28:49,429 INFO convert: progress: files_processed=447324 files_skipped=110649 bytes_processed=4975930566 lines_processed=29761938 bytes_per_sec=463529 lines_per_sec=2772
#2026-07-04 03:30:26,266 INFO convert: wrote 72826 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (30.6s, 2379 rows/s)
#2026-07-04 03:31:32,359 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 03:31:32,875 INFO botocore.tokens: SSO Token refresh succeeded
#2026-07-04 03:33:27,928 INFO convert: summary: files_processed=449168 files_skipped=110649 bytes_processed=4981943835 lines_processed=29800417 elapsed_sec=11013.4 avg_bytes_per_sec=452353 avg_lines_per_sec=2706
#2026-07-04 03:33:28,336 INFO cli: done: 449168 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

> time echo $DATE && python cli.py consolidate "${CT_CUST_A[@]}" --progress --workers 64
#2026/
#2026-07-04 00:40:57,706 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 00:40:58,646 INFO convert: resolved 18 source prefix(es) under s3://nri-cloudtrail-logs-637423466983/cloudtrail-logs/AWSLogs/637423466983/CloudTrail/*/2026/
#2026-07-04 00:41:36,469 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 00:41:54,206 INFO convert: 150566/187842 source files are new (unprocessed)
#2026-07-04 00:42:00,115 INFO convert: progress: files_processed=943 files_skipped=37276 bytes_processed=3208001 lines_processed=15369 bytes_per_sec=542901 lines_per_sec=2601
#2026-07-04 00:42:05,973 INFO convert: progress: files_processed=3841 files_skipped=37276 bytes_processed=12495602 lines_processed=53802 bytes_per_sec=1061940 lines_per_sec=4572
#2026-07-04 00:42:10,990 INFO convert: progress: files_processed=5671 files_skipped=37276 bytes_processed=17870978 lines_processed=78680 bytes_per_sec=1064749 lines_per_sec=4688
#2026-07-04 03:49:07,768 INFO convert: progress: files_processed=148737 files_skipped=37276 bytes_processed=7445275721 lines_processed=49512679 bytes_per_sec=662782 lines_per_sec=4408
#2026-07-04 03:49:55,797 INFO convert: wrote 184252 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (22.9s, 8032 rows/s)
#2026-07-04 03:50:17,907 INFO convert: summary: files_processed=150566 files_skipped=37276 bytes_processed=7449681647 lines_processed=49525927 elapsed_sec=11303.5 avg_bytes_per_sec=659059 avg_lines_per_sec=4381
#2026-07-04 03:50:18,081 INFO cli: done: 150566 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/

> time echo $DATE && python cli.py consolidate "${CT_DEV_A[@]}" --progress --workers 32
#2024
#2026-07-04 06:51:28,042 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 06:51:28,966 INFO convert: resolved 17 source prefix(es) under s3://aws-cloudtrail-logs-381492092437-74dbd159/AWSLogs/381492092437/CloudTrail/*/2024
#2026-07-04 06:52:07,845 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 06:52:23,252 INFO convert: 271729/271729 source files are new (unprocessed)
#2026-07-04 06:52:28,272 INFO convert: progress: files_processed=1275 files_skipped=0 bytes_processed=4802584 lines_processed=46049 bytes_per_sec=956788 lines_per_sec=9174
#2026-07-04 06:52:33,305 INFO convert: progress: files_processed=2561 files_skipped=0 bytes_processed=9377926 lines_processed=90878 bytes_per_sec=932893 lines_per_sec=9040
#2026-07-04 06:52:38,347 INFO convert: progress: files_processed=3772 files_skipped=0 bytes_processed=12916267 lines_processed=123150 bytes_per_sec=855670 lines_per_sec=8158

> time echo $DATE && python cli.py consolidate "${CT_NEWTON_A[@]}" --progress --workers 32
#2025
#2026-07-04 06:57:01,917 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 06:57:02,740 INFO convert: resolved 17 source prefix(es) under s3://aws-cloudtrail-logs-293034550673-c21dd2f3/AWSLogs/293034550673/CloudTrail/*/2025
#2026-07-04 06:57:13,162 INFO botocore.tokens: Loading cached SSO token for NRI_sso
#2026-07-04 06:57:40,767 INFO convert: 55944/55944 source files are new (unprocessed)
#2026-07-04 06:57:45,979 INFO convert: progress: files_processed=1 files_skipped=0 bytes_processed=994 lines_processed=3 bytes_per_sec=191 lines_per_sec=1
#2026-07-04 06:57:51,019 INFO convert: progress: files_processed=1705 files_skipped=0 bytes_processed=3787076 lines_processed=28312 bytes_per_sec=369383 lines_per_sec=2761
#2026-07-04 06:57:56,126 INFO convert: progress: files_processed=2998 files_skipped=0 bytes_processed=6593046 lines_processed=48713 bytes_per_sec=429258 lines_per_sec=3172
#2026-07-04 06:58:01,160 INFO convert: progress: files_processed=4225 files_skipped=0 bytes_processed=8913306 lines_processed=64442 bytes_per_sec=437085 lines_per_sec=3160
#2026-07-04 06:58:06,226 INFO convert: progress: files_processed=5761 files_skipped=0 bytes_processed=11765385 lines_processed=83449 bytes_per_sec=462130 lines_per_sec=3278
#2026-07-04 07:00:49,109 INFO convert: progress: files_processed=50689 files_skipped=0 bytes_processed=93076760 lines_processed=342338 bytes_per_sec=494192 lines_per_sec=1818
#2026-07-04 07:00:54,123 INFO convert: progress: files_processed=52249 files_skipped=0 bytes_processed=95930941 lines_processed=346709 bytes_per_sec=496139 lines_per_sec=1793
#2026-07-04 07:00:59,194 INFO convert: progress: files_processed=53249 files_skipped=0 bytes_processed=97736415 lines_processed=349395 bytes_per_sec=492558 lines_per_sec=1761
#2026-07-04 07:01:04,201 INFO convert: progress: files_processed=54772 files_skipped=0 bytes_processed=100716753 lines_processed=366753 bytes_per_sec=495085 lines_per_sec=1803
#2026-07-04 07:02:44,482 INFO convert: wrote 183275 rows -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/ (55.0s, 3335 rows/s)
#2026-07-04 07:03:30,598 INFO convert: summary: files_processed=55944 files_skipped=0 bytes_processed=103055904 lines_processed=383284 elapsed_sec=349.8 avg_bytes_per_sec=294589 avg_lines_per_sec=1096
#2026-07-04 07:03:30,823 INFO cli: done: 55944 new file(s) processed -> s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/raw/parquet/



```