@{
    # Выпуски Windows, которые знает LunqDebloater. Новый выпуск добавляется только здесь: по этой
    # таблице скрипт называет сборку (26200 это 25H2), ищет обновления в каталоге Microsoft и узнаёт
    # пакет включения среди накопительных обновлений.
    #   Build      номер сборки, как в версии образа 10.0.<Build>.<ревизия>;
    #   Product    'Windows 11' или 'Windows 10'; в каталоге ищутся только обновления Windows 11;
    #   Name       выпуск, как его пишет Microsoft в названиях обновлений (25H2);
    #   Enablement номер KB пакета включения, который переводит прошлый выпуск на этот, или пусто.
    # Пакет включения ставится после накопительного обновления и не вместе с ним (Add-LunqUpdates).
    Releases = @(
        @{ Build = 19045; Product = 'Windows 10'; Name = '22H2'; Enablement = '5015684' }
        @{ Build = 22000; Product = 'Windows 11'; Name = '21H2'; Enablement = '' }
        @{ Build = 22621; Product = 'Windows 11'; Name = '22H2'; Enablement = '' }
        @{ Build = 22631; Product = 'Windows 11'; Name = '23H2'; Enablement = '5027397' }
        @{ Build = 26100; Product = 'Windows 11'; Name = '24H2'; Enablement = '' }
        @{ Build = 26200; Product = 'Windows 11'; Name = '25H2'; Enablement = '5054156' }
        # Номер пакета включения 26H2 здесь не записан: впишите его, когда он будет известен.
        @{ Build = 26300; Product = 'Windows 11'; Name = '26H2'; Enablement = '' }
    )
}
