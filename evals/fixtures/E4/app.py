import os

DSN = "{}:{}@tcp({}:{})/app".format(
    os.environ["DB_USER"], os.environ["DB_PASSWORD"], os.environ["DB_HOST"], os.environ["DB_PORT"]
)
