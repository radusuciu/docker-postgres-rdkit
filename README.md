**NOTE**: I'm still experimenting with things in this repo!

# docker-postgres-rdkit

This project creates PostgreSQL docker images with the RDKit cartridge built and installed. GitHub actions are used to detect when new versions of either PostgreSQL or RDKit are released. Additionally, the version of `libboost` that is used is selected to match the version that the `rdkit` PyPI package is built with. Images are made pushed to the GitHub Container Registry (GHCR).

The image is based on the Dockerfile by [rvianello](https://github.com/rvianello/docker-postgres-rdkit/blob/master/Dockerfile).

## How to Use

Assuming you have docker installed, you can pull the image using:

```bash
docker pull ghcr.io/radusuciu/docker-postgres-rdkit/postgres-rdkit:<tag>
```

Tags follow the format `postgres-<pgversion>-rdkit-<rdkitversion>`, for example, postgres-15-rdkit-2023_03_2. You can find the available tags on the "Releases" page of this GitHub repository. Each release also has a corresponding branch in this repository.

To run the Docker container, use:

```bash
docker run -d ghcr.io/radusuciu/docker-postgres-rdkit/postgres-rdkit:<tag> bash
```

Replace <tag> with the version tag of the Docker image.

## Available Versions

<!-- start automatically generated version matrix -->
| PostgreSQL | RDKit | Boost |
| --- | --- | --- |
| 14.8 | 2022_03_3 | 1.74 |
| 14.8 | 2022_03_4 | 1.74 |
| 15.2 | 2023_03_1 | 1.78 |
| 15.3 | 2023_03_2 | 1.78 |
<!-- end automatically generated version matrix -->

## Configuration

This immage is based on the official postgres image, see [here](https://hub.docker.com/_/postgres) for details on configuration.

For details on use of the rdkit cartridge, refer to the [rdkit docs on the matter](https://www.rdkit.org/docs/Cartridge.html).

## Building the Docker Image

This project uses GitHub Actions to automatically build a new Docker image when new versions of PostgreSQL, RDKit or Boost are released. The workflow file that controls this process is `.github/workflows/check_versions.yml`. It checks for new versions of these components daily, and if it finds any new versions, it creates a new branch, and updates the Dockerfile if a new version of boost is found (rdkit and postgres versions are handled as build-args). A separate workflow, `github/workflows/build_and_push` builds and pushes new images, extracting rdkit and postgres versions from the branch name.

If you want to build the Docker image manually, you can use the following command:

```bash
docker build -t <your_tag> --build-arg postgres_image_version=<pg_version> --build-arg postgres_major_version=<pg_major_version> --build-arg rdkit_git_ref=Release_<rdkit_version> .
```

When building the Docker image, you can specify several parameters, including:

* `postgres_image_version`: The version of the PostgreSQL image to use. Formatted like: `14.8`.
* `postgres_major_version`: The major version of PostgreSQL. Formatted like: `15`.
* `rdkit_git_ref`: The version of RDKit to use. This should correspond to a GitHub release tag of the RDKit project. Formatted like: `Release_2023_03_3`.
* `boost_version`: Optional. The version of `libboost` to use. Formatted like `1.74` or `1.74.0`.

## Credits and other projects

The image is based on the Dockerfile by [rvianello](https://github.com/rvianello/docker-postgres-rdkit/blob/master/Dockerfile).

Here is a non-exhaustive list of other projects that do something similar:
* [`docker-postgres-rdkit`](https://github.com/rvianello/docker-postgres-rdkit) by rvianello
* [`docker-postgres-rdkit`](https://github.com/mcs07/docker-postgres-rdkit) by mcs07
* [`docker-postgres-rdkit`](https://github.com/v-kamerdinerov/docker-postgres-rdkit) by v-kamerdinerov
* [`docker-postgres-rdkit`](https://github.com/joelduerksen/docker-postgres-rdkit) by joelduerksen

The main difference between these projects and this one is that I'm attempting to automate the creation of images as much as possible, to ensure that all version combinations going forward (and a few historical) are covered.

This project was put together with a lot of prodding of ChatGPT.
