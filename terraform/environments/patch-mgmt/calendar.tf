# 変更凍結用のカレンダー(Change Calendar)。年末年始などの期間をCLOSEDにして、
# パッチ適用(install-now・gated-patch-baseline)を止めるために使う想定。
#
# 中身(documents/holiday-calendar.ics)は現時点では検証用の短いCLOSED期間だけが
# 入っている。実運用で使う休暇期間に書き換えること。
# 状態の確認: aws ssm get-calendar-state --calendar-names <このリソースのname>
resource "aws_ssm_document" "holiday_calendar" {
  name            = "${local.name}-holiday-calendar"
  document_type   = "ChangeCalendar"
  document_format = "TEXT"
  content         = file("${path.module}/documents/holiday-calendar.ics")
}
