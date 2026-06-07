const username = process.env.MONGO_APP_USERNAME;
const password = process.env.MONGO_APP_PASSWORD;

if (!username || !password) {
  throw new Error('MONGO_APP_USERNAME and MONGO_APP_PASSWORD are required');
}

['ride_service', 'notification_service'].forEach((dbName) => {
  const serviceDb = db.getSiblingDB(dbName);
  if (!serviceDb.getUser(username)) {
    serviceDb.createUser({
      user: username,
      pwd: password,
      roles: [{ role: 'readWrite', db: dbName }]
    });
  }
});
