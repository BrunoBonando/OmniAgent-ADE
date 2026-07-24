import helpers


def fetch_data(url):
    config = helpers.parse_config("config.ini")
    return {"url": url, "config": config}
