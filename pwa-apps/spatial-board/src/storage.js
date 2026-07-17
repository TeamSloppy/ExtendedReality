const databaseName = 'extend-reality-spatial-board'
const storeName = 'boards'
const activeBoardKey = 'active-board'

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1)
    request.onerror = () => reject(request.error)
    request.onupgradeneeded = () => {
      request.result.createObjectStore(storeName)
    }
    request.onsuccess = () => resolve(request.result)
  })
}

async function transact(mode, operation) {
  const database = await openDatabase()
  try {
    return await new Promise((resolve, reject) => {
      const transaction = database.transaction(storeName, mode)
      const request = operation(transaction.objectStore(storeName))
      request.onerror = () => reject(request.error)
      request.onsuccess = () => resolve(request.result)
    })
  } finally {
    database.close()
  }
}

export async function loadBoard() {
  return transact('readonly', (store) => store.get(activeBoardKey))
}

export async function saveBoard(board) {
  return transact('readwrite', (store) => store.put(board, activeBoardKey))
}
