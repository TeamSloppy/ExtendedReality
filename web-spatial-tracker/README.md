# Spatial Debug Station

Локальный WebSocket relay и браузерный viewer для датчиков Extend Reality и
пространственного расположения окон. Внешних npm-зависимостей нет.

## Быстрый запуск

```sh
cd web-spatial-tracker
npm start
```

Откройте `http://localhost:4173` на Mac. Сервер также напечатает LAN-адрес,
например `http://192.168.1.20:4173`.

### Existing ExtendReality iOS app

В Xcode откройте **Scheme → Run → Arguments** и добавьте launch argument:

```text
-debugSocketURL ws://YOUR-MAC.local:4173/ws?role=device&id=iphone
```

Вместо `YOUR-MAC.local` можно использовать LAN IP, напечатанный сервером.
Запустите приложение на iPhone. Отправитель активируется только при наличии
этого аргумента и передаёт 20 снимков в секунду:

- AirPods head pose и статус подключения;
- attitude, acceleration, gravity и rotation rate телефона;
- статус Apple Watch;
- все workspace windows, их transform, размер, z-index, focus и minimized.

Телефон и Mac должны находиться в одной локальной сети. Точка доступа телефона
тоже подходит, если устройства видят друг друга.

Relay слушает все сетевые интерфейсы и не использует авторизацию — запускайте
его только в доверенной локальной сети и останавливайте после отладки.

### Browser sensor test

Откройте на телефоне адрес, который сервер печатает как `Phone sender`, например:

```text
http://192.168.1.20:4173/?mode=device
```

Нажмите **Enable sensors**. Это тестовый producer; некоторые мобильные браузеры
разрешают DeviceMotion только в secure context. Нативный iOS sender выше не имеет
этого ограничения.

## WebSocket protocol

Relay endpoint:

```text
ws://HOST:4173/ws?role=device&id=DEVICE_ID
ws://HOST:4173/ws?role=viewer&id=VIEWER_ID
```

`device` отправляет JSON; relay без изменения пересылает его всем `viewer`,
добавляя `sourceClient`, `sourceRole` и `serverReceivedAt`.

Минимальный payload:

```json
{
  "type": "snapshot",
  "timestamp": 1784296800000,
  "device": { "id": "iphone", "name": "iPhone", "platform": "iOS" },
  "sensors": {
    "head": {
      "orientation": { "yaw": 12.4, "pitch": -3.1, "roll": 0.8 },
      "source": "AirPods"
    },
    "phone": {
      "orientation": { "yaw": 10, "pitch": 2, "roll": 1 },
      "acceleration": { "x": 0.1, "y": 0.0, "z": -0.2 }
    },
    "watch": { "connected": true }
  },
  "devices": {
    "head": { "position": { "x": 0, "y": 0.35, "z": 0 } },
    "phone": { "position": { "x": 0.86, "y": -0.42, "z": 0.24 } },
    "watch": { "position": { "x": -0.72, "y": -0.4, "z": 0.15 } }
  },
  "windows": [
    {
      "id": "browser",
      "title": "Browser",
      "position": { "x": 0, "y": 0.25, "z": -2.7 },
      "rotation": { "yaw": 0, "pitch": 0, "roll": 0 },
      "size": { "width": 1.4, "height": 0.85 },
      "focused": true
    }
  ]
}
```

Координаты и размеры — в метрах, углы — в градусах, timestamp — Unix time в
миллисекундах. Viewer также принимает текущий `WindowTransform3DoF` в поле
`transform` и сам переводит yaw/pitch/distance в позицию сцены.

Для прямого подключения к другому WebSocket-серверу вставьте его URL в поле
**WEBSOCKET** в верхней панели viewer.
