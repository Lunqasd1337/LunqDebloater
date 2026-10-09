# Безопасность

English: [see below](#security-policy)

## Какие версии поддерживаются

Исправления выходят только для последней версии из [Releases](https://github.com/Lunqasd1337/LunqDebloater/releases). Если проблема есть в старой версии, проверьте, повторяется ли она в последней.

## Как сообщить об уязвимости

Не описывайте уязвимость в открытом issue. Сообщите о ней закрыто: на GitHub откройте вкладку **Security**, затем **Report a vulnerability**. Если такой кнопки нет, откройте issue с заголовком «Уязвимость» без подробностей, и мы договоримся, куда прислать описание.

Напишите, что именно не так, как это повторить (версия LunqDebloater, параметры запуска, профиль) и к чему это приводит. Владелец репозитория ответит, как только сможет. Когда исправление выйдет, оно будет описано в [CHANGELOG.md](../CHANGELOG.md).

## Что считается уязвимостью

Например:

- собранный образ получает настройку, которая ослабляет защиту, хотя профиль её не просил;
- скрипт первого входа или файл ответов дают кому-то лишние права или выполняют чужой код;
- скрипт пишет в лог или в образ пароли и другие данные, которые не должен.

Удаление компонентов, о котором просит профиль, уязвимостью не считается: это делается на свой страх и риск (см. раздел «Ответственность» в [README.md](../README.md)).

---

## Security policy

### Supported versions

Fixes are released only for the latest version on [Releases](https://github.com/Lunqasd1337/LunqDebloater/releases). If you found a problem in an older version, check whether it still happens in the latest one.

### Reporting a vulnerability

Do not describe a vulnerability in a public issue. Report it privately: on GitHub open the **Security** tab, then **Report a vulnerability**. If that button is missing, open an issue titled "Vulnerability" without details, and we will agree on where to send the description.

Describe what is wrong, how to reproduce it (LunqDebloater version, parameters, profile) and what it leads to. The repository owner will answer as soon as possible. Once the fix is released, it is described in [CHANGELOG.md](../CHANGELOG.md).

### What counts as a vulnerability

For example:

- the built image gets a setting that weakens security although the profile did not ask for it;
- the first sign-in script or the answer file gives someone extra rights or runs someone else's code;
- the script writes passwords or other data it should not into the log or the image.

Removing components that the profile asks for is not a vulnerability: you do it at your own risk (see the "Disclaimer" section in [README.en.md](../README.en.md)).
