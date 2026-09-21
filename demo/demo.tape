Output demo.gif

Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 18
Set Width 1000
Set Height 400
Set Padding 10
Set Theme "nord"

Hide
Type "nvim /work/src/sync.ts" Enter
Sleep 1s
Type ":DifftSigns toggle" Enter
Sleep 200ms
Type ":echo 'plain gitsigns'" Enter
Show

Sleep 1.5s
Type ":DifftSigns toggle" Enter
Sleep 200ms
Type ":echo 'with difftsigns'" Enter
Sleep 1.5s

Type "2j"
Sleep 200ms
Type ":DifftSigns preview" Enter
Sleep 2.5s
