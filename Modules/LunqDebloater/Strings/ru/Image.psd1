# Строки Private\Image.ps1.
@{
    'Image.CleanupFailed'      = 'Очистка хранилища компонентов не удалась (dism.exe вернул код {0}), образ будет больше. Подробности в логе DISM.'
    'Image.OscdimgNotFoundAt'  = 'oscdimg.exe не найден по пути {0}'
    'Image.OscdimgNotFound'    = 'oscdimg.exe не найден. Установите Windows ADK (компонент Deployment Tools) или укажите -OscdimgPath.'
    'Image.BootFileMissing'    = 'Не найден загрузочный файл {0}'
    'Image.FolderNameHasSpace' = 'В имени папки {0} есть пробел, oscdimg не сможет собрать ISO.'
    'Image.OscdimgFailed'      = 'oscdimg завершился с кодом {0}'
    'Image.IsoReplaceFailed'   = 'Образ собран, но заменить {0} не удалось: {1} Готовый образ лежит в {2}.'
    'Image.SplitTitle'         = 'Разделение install.wim'
    'Image.SplitDone'          = '{0} разделён на части по {2} МБ: {1} шт. (install.swm), флешка может быть FAT32'
    'Image.SplitNoParts'       = 'Split-WindowsImage не создал {0}'
    'Image.WimSizeTitle'       = 'Размер install.wim'
    'Image.WimTooBig'          = 'install.wim занимает {0}, а на флешку FAT32 помещаются файлы до 4 ГБ. Запишите ISO через Rufus (он сам разделит образ или отформатирует флешку в NTFS) или соберите с -SplitWim.'
    'Image.WimTooBigSummary'   = '{0}, больше 4 ГБ: для флешки FAT32 нужен Rufus или -SplitWim'
}
