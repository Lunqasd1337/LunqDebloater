# Удаляет Microsoft Edge при первом входе в Windows скриптом EdgeRemover от he3als
# (https://github.com/he3als/EdgeRemover). Он лежит в папке EdgeRemover как в оригинале, только
# с BOM, чтобы обновить его можно было заменой файла. Без параметров он открывает меню и ждёт
# клавишу, а первый вход идёт без вопросов, поэтому он запускается с -UninstallEdge -NonInteractive.
# Чтобы Edge оставался, удалите этот файл вместе с папкой EdgeRemover или соберите с -SkipScripts.
& (Join-Path (Join-Path $PSScriptRoot 'EdgeRemover') 'RemoveEdge.ps1') -UninstallEdge -NonInteractive
# Код выхода передаётся дальше: по нему FirstLogon.ps1 пишет в лог, что удаление не удалось.
exit $LASTEXITCODE
