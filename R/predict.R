predict_internal <- function(draws, ...) {
  UseMethod("predict_internal")
}

#' @export
predict_internal.mvbrmsdraws <- function(draws, ...) {
  if (length(draws$mvpars$rescor)) {
    draws$mvpars$Mu <- get_Mu(draws)
    draws$mvpars$Sigma <- get_Sigma(draws)
    out <- predict_internal.brmsdraws(draws, ...)
  } else {
    out <- lapply(draws$resps, predict_internal, ...)
    along <- ifelse(length(out) > 1L, 3, 2)
    out <- do_call(abind, c(out, along = along))
  }
  out
}

#' @export
predict_internal.brmsdraws <- function(draws, summary = TRUE, transform = NULL,
                                       sort = FALSE, robust = FALSE, 
                                       probs = c(0.025, 0.975), ...) {
  for (nlp in names(draws$nlpars)) {
    draws$nlpars[[nlp]] <- get_nlpar(draws, nlpar = nlp)
  }
  for (dp in names(draws$dpars)) {
    draws$dpars[[dp]] <- get_dpar(draws, dpar = dp)
  }
  predict_fun <- paste0("predict_", draws$family$fun)
  predict_fun <- get(predict_fun, asNamespace("brms"))
  N <- choose_N(draws)
  out <- lapply(seq_len(N), predict_fun, draws = draws, ...)
  if (grepl("_mv$", draws$family$fun)) {
    out <- do_call(abind, c(out, along = 3))
    out <- aperm(out, perm = c(1, 3, 2))
    dimnames(out)[[3]] <- names(draws$resps)
  } else if (has_multicol(draws$family)) {
    out <- do_call(abind, c(out, along = 3))
    out <- aperm(out, perm = c(1, 3, 2))
    dimnames(out)[[3]] <- draws$data$cats
  } else {
    out <- do_call(cbind, out) 
  }
  colnames(out) <- NULL
  if (use_int(draws$family)) {
    out <- check_discrete_trunc_bounds(
      out, lb = draws$data$lb, ub = draws$data$ub
    )
  }
  out <- reorder_obs(out, draws$old_order, sort = sort)
  # transform predicted response samples before summarizing them 
  if (!is.null(transform)) {
    out <- do_call(transform, list(out))
  }
  attr(out, "levels") <- draws$data$cats
  if (summary) {
    if (is_ordinal(draws$family) || is_categorical(draws$family)) {
      out <- posterior_table(out, levels = seq_len(draws$data$ncat))
    } else {
      out <- posterior_summary(out, probs = probs, robust = robust)
    }
  }
  out
}

# All predict_<family> functions have the same arguments structure
# @param i the column of draws to use that is the ith obervation 
#   in the initial data.frame 
# @param draws A named list returned by extract_draws containing 
#   all required data and samples
# @param ... ignored arguments
# @param A vector of length draws$nsamples containing samples
#   from the posterior predictive distribution
predict_gaussian <- function(i, draws, ...) {
  args <- list(
    mean = get_dpar(draws, "mu", i = i), 
    sd = get_dpar(draws, "sigma", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "norm", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_student <- function(i, draws, ...) {
  args <- list(
    df = get_dpar(draws, "nu", i = i), 
    mu = get_dpar(draws, "mu", i = i), 
    sigma = get_dpar(draws, "sigma", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "student_t", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_lognormal <- function(i, draws, ...) {
  args <- list(
    meanlog = get_dpar(draws, "mu", i = i), 
    sdlog = get_dpar(draws, "sigma", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "lnorm", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_shifted_lognormal <- function(i, draws, ...) {
  args <- list(
    meanlog = get_dpar(draws, "mu", i = i), 
    sdlog = get_dpar(draws, "sigma", i = i),
    shift = get_dpar(draws, "ndt", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "shifted_lnorm", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_skew_normal <- function(i, draws, ...) {
  sigma <- get_dpar(draws, "sigma", i = i)
  alpha <- get_dpar(draws, "alpha", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  args <- nlist(mu, sigma, alpha)
  rng_continuous(
    nrng = draws$nsamples, dist = "skew_normal", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_gaussian_mv <- function(i, draws, ...) {
  Mu <- get_Mu(draws, i = i)
  Sigma <- get_Sigma(draws, i = i)
  .predict <- function(s) {
    rmulti_normal(1, mu = Mu[s, ], Sigma = Sigma[s, , ])
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_student_mv <- function(i, draws, ...) {
  nu <- get_dpar(draws, "nu", i = i)
  Mu <- get_Mu(draws, i = i)
  Sigma <- get_Sigma(draws, i = i)
  .predict <- function(s) {
    rmulti_student_t(1, df = nu[s], mu = Mu[s, ], Sigma = Sigma[s, , ])
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_gaussian_cov <- function(i, draws, ...) {
  obs <- with(draws$ac, begin_tg[i]:end_tg[i])
  mu <- as.matrix(get_dpar(draws, "mu", i = obs))
  Sigma <- get_cov_matrix_arma(draws, obs)
  .predict <- function(s) {
    rmulti_normal(1, mu = mu[s, ], Sigma = Sigma[s, , ])
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_student_cov <- function(i, draws, ...) {
  obs <- with(draws$ac, begin_tg[i]:end_tg[i])
  nu <- as.matrix(get_dpar(draws, "nu", i = obs))
  mu <- as.matrix(get_dpar(draws, "mu", i = obs))
  Sigma <- get_cov_matrix_arma(draws, obs)
  .predict <- function(s) {
    rmulti_student_t(1, df = nu[s, ], mu = mu[s, ], Sigma = Sigma[s, , ])
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_gaussian_lagsar <- function(i, draws, ...) {
  stopifnot(i == 1)
  .predict <- function(s) {
    W_new <- with(draws, diag(nobs) - ac$lagsar[s] * ac$W)
    mu <- as.numeric(solve(W_new) %*% mu[s, ])
    Sigma <- solve(crossprod(W_new)) * sigma[s]^2
    rmulti_normal(1, mu = mu, Sigma = Sigma)
  }
  mu <- get_dpar(draws, "mu")
  sigma <- get_dpar(draws, "sigma")
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_student_lagsar <- function(i, draws, ...) {
  stopifnot(i == 1)
  .predict <- function(s) {
    W_new <- with(draws, diag(nobs) - ac$lagsar[s] * ac$W)
    mu <- as.numeric(solve(W_new) %*% mu[s, ])
    Sigma <- solve(crossprod(W_new)) * sigma[s]^2
    rmulti_student_t(1, df = nu[s], mu = mu, Sigma = Sigma)
  }
  mu <- get_dpar(draws, "mu")
  sigma <- get_dpar(draws, "sigma")
  nu <- get_dpar(draws, "nu")
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_gaussian_errorsar <- function(i, draws, ...) {
  stopifnot(i == 1)
  .predict <- function(s) {
    W_new <- with(draws, diag(nobs) - ac$errorsar[s] * ac$W)
    Sigma <- solve(crossprod(W_new)) * sigma[s]^2
    rmulti_normal(1, mu = mu[s, ], Sigma = Sigma)
  }
  mu <- get_dpar(draws, "mu")
  sigma <- get_dpar(draws, "sigma")
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_student_errorsar <- function(i, draws, ...) {
  stopifnot(i == 1)
  .predict <- function(s) {
    W_new <- with(draws, diag(nobs) - ac$errorsar[s] * ac$W)
    Sigma <- solve(crossprod(W_new)) * sigma[s]^2
    rmulti_student_t(1, df = nu[s], mu = mu[s, ], Sigma = Sigma)
  }
  mu <- get_dpar(draws, "mu")
  sigma <- get_dpar(draws, "sigma")
  nu <- get_dpar(draws, "nu")
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_gaussian_fixed <- function(i, draws, ...) {
  stopifnot(i == 1)
  mu <- as.matrix(get_dpar(draws, "mu"))
  .predict <- function(s) {
    rmulti_normal(1, mu = mu[s, ], Sigma = draws$ac$V)
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_student_fixed <- function(i, draws, ...) {
  stopifnot(i == 1)
  mu <- as.matrix(get_dpar(draws, "mu"))
  nu <- as.matrix(get_dpar(draws, "nu"))
  .predict <- function(s) {
    rmulti_student_t(1, df = nu[s, ], mu = mu[s, ], Sigma = draws$ac$V)
  }
  rblapply(seq_len(draws$nsamples), .predict)
}

predict_binomial <- function(i, draws, ntrys = 5, ...) {
  args <- list(
    size = draws$data$trials[i], 
    prob = get_dpar(draws, "mu", i = i)
  )
  rng_discrete(
    nrng = draws$nsamples, dist = "binom", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i], 
    ntrys = ntrys
  )
}

predict_bernoulli <- function(i, draws, ...) {
  mu <- get_dpar(draws, "mu", i = i)
  rbinom(length(mu), size = 1, prob = mu)
}

predict_poisson <- function(i, draws, ntrys = 5, ...) {
  args <- list(lambda = get_dpar(draws, "mu", i = i))
  rng_discrete(
    nrng = draws$nsamples, dist = "pois", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i],
    ntrys = ntrys
  )
}

predict_negbinomial <- function(i, draws, ntrys = 5, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    size = get_dpar(draws, "shape", i = i)
  )
  rng_discrete(
    nrng = draws$nsamples, dist = "nbinom", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i],
    ntrys = ntrys
  )
}

predict_geometric <- function(i, draws, ntrys = 5, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    size = 1
  )
  rng_discrete(
    nrng = draws$nsamples, dist = "nbinom", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i], 
    ntrys = ntrys
  )
}

predict_discrete_weibull <- function(i, draws, ntrys = 5, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    shape = get_dpar(draws, "shape", i = i)
  )
  rng_discrete(
    nrng = draws$nsamples, dist = "discrete_weibull", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i],
    ntrys = ntrys
  )
}

predict_com_poisson <- function(i, draws, ntrys = 5, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    shape = get_dpar(draws, "shape", i = i)
  )
  rng_discrete(
    nrng = draws$nsamples, dist = "com_poisson", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i],
    ntrys = ntrys
  )
}

predict_exponential <- function(i, draws, ...) {
  args <- list(rate = 1 / get_dpar(draws, "mu", i = i))
  rng_continuous(
    nrng = draws$nsamples, dist = "exp", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_gamma <- function(i, draws, ...) {
  shape <- get_dpar(draws, "shape", i = i)
  args <- nlist(shape, scale = get_dpar(draws, "mu", i = i) / shape)
  rng_continuous(
    nrng = draws$nsamples, dist = "gamma", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_weibull <- function(i, draws, ...) {
  shape <- get_dpar(draws, "shape", i = i)
  scale <- get_dpar(draws, "mu", i = i) / gamma(1 + 1 / shape) 
  args <- list(shape = shape, scale = scale)
  rng_continuous(
    nrng = draws$nsamples, dist = "weibull", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_frechet <- function(i, draws, ...) {
  nu <- get_dpar(draws, "nu", i = i)
  scale <- get_dpar(draws, "mu", i = i) / gamma(1 - 1 / nu)
  args <- list(scale = scale, shape = nu)
  rng_continuous(
    nrng = draws$nsamples, dist = "frechet", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_gen_extreme_value <- function(i, draws, ...) {
  sigma <- get_dpar(draws, "sigma", i = i)
  xi <- get_dpar(draws, "xi", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  args <- nlist(mu, sigma, xi)
  rng_continuous(
    nrng = draws$nsamples, dist = "gen_extreme_value", 
    args = args, lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_inverse.gaussian <- function(i, draws, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    shape = get_dpar(draws, "shape", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "inv_gaussian", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_exgaussian <- function(i, draws, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    sigma = get_dpar(draws, "sigma", i = i),
    beta = get_dpar(draws, "beta", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "exgaussian", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_wiener <- function(i, draws, negative_rt = FALSE, ...) {
  args <- list(
    delta = get_dpar(draws, "mu", i = i), 
    alpha = get_dpar(draws, "bs", i = i),
    tau = get_dpar(draws, "ndt", i = i),
    beta = get_dpar(draws, "bias", i = i),
    types = if (negative_rt) c("q", "resp") else "q"
  )
  out <- rng_continuous(
    nrng = 1, dist = "wiener", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
  if (negative_rt) {
    # code lower bound responses as negative RTs
    out <- out[["q"]] * ifelse(out[["resp"]], 1, -1)
  }
  out
}

predict_beta <- function(i, draws, ...) {
  mu <- get_dpar(draws, "mu", i = i)
  phi <- get_dpar(draws, "phi", i = i)
  args <- list(shape1 = mu * phi, shape2 = (1 - mu) * phi)
  rng_continuous(
    nrng = draws$nsamples, dist = "beta", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_von_mises <- function(i, draws, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    kappa = get_dpar(draws, "kappa", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "von_mises", args = args,
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_asym_laplace <- function(i, draws, ...) {
  args <- list(
    mu = get_dpar(draws, "mu", i = i), 
    sigma = get_dpar(draws, "sigma", i = i),
    quantile = get_dpar(draws, "quantile", i = i)
  )
  rng_continuous(
    nrng = draws$nsamples, dist = "asym_laplace", args = args, 
    lb = draws$data$lb[i], ub = draws$data$ub[i]
  )
}

predict_hurdle_poisson <- function(i, draws, ...) {
  # theta is the bernoulli hurdle parameter
  theta <- get_dpar(draws, "hu", i = i) 
  lambda <- get_dpar(draws, "mu", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the hurdle process
  hu <- runif(ndraws, 0, 1)
  # sample from a truncated poisson distribution
  # by adjusting lambda and adding 1
  t = -log(1 - runif(ndraws) * (1 - exp(-lambda)))
  ifelse(hu < theta, 0, rpois(ndraws, lambda = lambda - t) + 1)
}

predict_hurdle_negbinomial <- function(i, draws, ...) {
  # theta is the bernoulli hurdle parameter
  theta <- get_dpar(draws, "hu", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the hurdle process
  hu <- runif(ndraws, 0, 1)
  # sample from an approximate(!) truncated negbinomial distribution
  # by adjusting mu and adding 1
  t = -log(1 - runif(ndraws) * (1 - exp(-mu)))
  shape <- get_dpar(draws, "shape", i = i)
  ifelse(hu < theta, 0, rnbinom(ndraws, mu = mu - t, size = shape) + 1)
}

predict_hurdle_gamma <- function(i, draws, ...) {
  # theta is the bernoulli hurdle parameter
  theta <- get_dpar(draws, "hu", i = i)
  shape <- get_dpar(draws, "shape", i = i)
  scale <- get_dpar(draws, "mu", i = i) / shape
  ndraws <- draws$nsamples
  # compare with theta to incorporate the hurdle process
  hu <- runif(ndraws, 0, 1)
  ifelse(hu < theta, 0, rgamma(ndraws, shape = shape, scale = scale))
}

predict_hurdle_lognormal <- function(i, draws, ...) {
  # theta is the bernoulli hurdle parameter
  theta <- get_dpar(draws, "hu", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  sigma <- get_dpar(draws, "sigma", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the hurdle process
  hu <- runif(ndraws, 0, 1)
  ifelse(hu < theta, 0, rlnorm(ndraws, meanlog = mu, sdlog = sigma))
}

predict_zero_inflated_beta <- function(i, draws, ...) {
  # theta is the bernoulli hurdle parameter
  theta <- get_dpar(draws, "zi", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  phi <- get_dpar(draws, "phi", i = i)
  # compare with theta to incorporate the hurdle process
  hu <- runif(draws$nsamples, 0, 1)
  ifelse(
    hu < theta, 0, 
    rbeta(draws$nsamples, shape1 = mu * phi, shape2 = (1 - mu) * phi)
  )
}

predict_zero_one_inflated_beta <- function(i, draws, ...) {
  zoi <- get_dpar(draws, "zoi", i)
  coi <- get_dpar(draws, "coi", i)
  mu <- get_dpar(draws, "mu", i = i)
  phi <- get_dpar(draws, "phi", i = i)
  hu <- runif(draws$nsamples, 0, 1)
  one_or_zero <- runif(draws$nsamples, 0, 1)
  ifelse(hu < zoi, 
    ifelse(one_or_zero < coi, 1, 0),
    rbeta(draws$nsamples, shape1 = mu * phi, shape2 = (1 - mu) * phi)
  )
}

predict_zero_inflated_poisson <- function(i, draws, ...) {
  # theta is the bernoulli zero-inflation parameter
  theta <- get_dpar(draws, "zi", i = i)
  lambda <- get_dpar(draws, "mu", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the zero-inflation process
  zi <- runif(ndraws, 0, 1)
  ifelse(zi < theta, 0, rpois(ndraws, lambda = lambda))
}

predict_zero_inflated_negbinomial <- function(i, draws, ...) {
  # theta is the bernoulli zero-inflation parameter
  theta <- get_dpar(draws, "zi", i = i)
  mu <- get_dpar(draws, "mu", i = i)
  shape <- get_dpar(draws, "shape", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the zero-inflation process
  zi <- runif(ndraws, 0, 1)
  ifelse(zi < theta, 0, rnbinom(ndraws, mu = mu, size = shape))
}

predict_zero_inflated_binomial <- function(i, draws, ...) {
  # theta is the bernoulii zero-inflation parameter
  theta <- get_dpar(draws, "zi", i = i)
  trials <- draws$data$trials[i]
  prob <- get_dpar(draws, "mu", i = i)
  ndraws <- draws$nsamples
  # compare with theta to incorporate the zero-inflation process
  zi <- runif(ndraws, 0, 1)
  ifelse(zi < theta, 0, rbinom(ndraws, size = trials, prob = prob))
}

predict_categorical <- function(i, draws, ...) {
  eta <- sapply(names(draws$dpars), get_dpar, draws = draws, i = i)
  eta <- insert_refcat(eta, family = draws$family)
  p <- pcategorical(seq_len(draws$data$ncat), eta = eta)
  first_greater(p, target = runif(draws$nsamples, min = 0, max = 1))
}

predict_multinomial <- function(i, draws, ...) {
  eta <- sapply(names(draws$dpars), get_dpar, draws = draws, i = i)
  eta <- insert_refcat(eta, family = draws$family)
  p <- pcategorical(seq_len(draws$data$ncat), eta = eta)
  size <- draws$data$trials[i]
  out <- lapply(seq_rows(p), function(s) t(rmultinom(1, size, p[s, ])))
  do_call(rbind, out)
}

predict_dirichlet <- function(i, draws, ...) {
  mu_dpars <- str_subset(names(draws$dpars), "^mu")
  eta <- sapply(mu_dpars, get_dpar, draws = draws, i = i)
  eta <- insert_refcat(eta, family = draws$family)
  phi <- get_dpar(draws, "phi", i = i)
  cats <- seq_len(draws$data$ncat)
  alpha <- dcategorical(cats, eta = eta) * phi
  rdirichlet(draws$nsamples, alpha = alpha)
}

predict_cumulative <- function(i, draws, ...) {
  predict_ordinal(i = i, draws = draws)
}

predict_sratio <- function(i, draws, ...) {
  predict_ordinal(i = i, draws = draws)
}

predict_cratio <- function(i, draws, ...) {
  predict_ordinal(i = i, draws = draws)
}

predict_acat <- function(i, draws, ...) {
  predict_ordinal(i = i, draws = draws)
}  

predict_ordinal <- function(i, draws, ...) {
  p <- pordinal(
    seq_len(draws$data$ncat), 
    eta = get_dpar(draws, "mu", i = i), 
    disc = get_dpar(draws, "disc", i = i),
    thres = draws$thres, 
    family = draws$family$family, 
    link = draws$family$link
  )
  first_greater(p, target = runif(draws$nsamples, min = 0, max = 1))
}

predict_custom <- function(i, draws, ...) {
  predict_fun <- draws$family$predict
  if (!is.function(predict_fun)) {
    predict_fun <- paste0("predict_", draws$family$name)
    predict_fun <- get(predict_fun, draws$family$env)
  }
  predict_fun(i = i, draws = draws, ...)
}

predict_mixture <- function(i, draws, ...) {
  families <- family_names(draws$family)
  theta <- get_theta(draws, i = i)
  smix <- rng_mix(theta)
  out <- rep(NA, draws$nsamples)
  for (j in seq_along(families)) {
    sample_ids <- which(smix == j)
    if (length(sample_ids)) {
      predict_fun <- paste0("predict_", families[j])
      predict_fun <- get(predict_fun, asNamespace("brms"))
      tmp_draws <- pseudo_draws_for_mixture(draws, j, sample_ids)
      out[sample_ids] <- predict_fun(i, tmp_draws, ...)
    }
  }
  out
}

# ------------ predict helper-functions ----------------------
# random numbers from (possibly truncated) continuous distributions
# @param nrng number of random values to generate
# @param dist name of a distribution for which the functions
#   p<dist>, q<dist>, and r<dist> are available
# @param args additional arguments passed to the distribution functions
# @return vector of random values draws from the distribution
rng_continuous <- function(nrng, dist, args, lb = NULL, ub = NULL) {
  if (is.null(lb) && is.null(ub)) {
    # sample as usual
    rdist <- paste0("r", dist)
    out <- do_call(rdist, c(nrng, args))
  } else {
    # sample from truncated distribution
    if (is.null(lb)) lb <- -Inf
    if (is.null(ub)) ub <- Inf
    pdist <- paste0("p", dist)
    qdist <- paste0("q", dist)
    plb <- do_call(pdist, c(list(lb), args))
    pub <- do_call(pdist, c(list(ub), args))
    rng <- list(runif(nrng, min = plb, max = pub))
    out <- do_call(qdist, c(rng, args))
    # remove infinte values caused by numerical imprecision
    out[out %in% c(-Inf, Inf)] <- NA
  }
  out
}

# random numbers from (possibly truncated) discrete distributions
# currently rejection sampling is used for truncated distributions
# @param nrng number of random values to generate
# @param dist name of a distribution for which the functions
#   p<dist>, q<dist>, and r<dist> are available
# @param args dditional arguments passed to the distribution functions
# @param lb optional lower truncation bound
# @param ub optional upper truncation bound
# @param ntrys number of trys in rejection sampling for truncated models
# @return a vector of random values draws from the distribution
rng_discrete <- function(nrng, dist, args, lb = NULL, ub = NULL, ntrys = 5) {
  rdist <- get(paste0("r", dist), mode = "function")
  if (is.null(lb) && is.null(ub)) {
    # sample as usual
    do_call(rdist, c(nrng, args))
  } else {
    # sample from truncated distribution via rejection sampling
    if (is.null(lb)) lb <- -Inf
    if (is.null(ub)) ub <- Inf
    rng <- matrix(do_call(rdist, c(nrng * ntrys, args)), ncol = ntrys)
    apply(rng, 1, extract_valid_sample, lb = lb, ub = ub)
  }
}

# sample the ID of the mixture component
rng_mix <- function(theta) {
  stopifnot(is.matrix(theta))
  mix_comp <- seq_cols(theta)
  ulapply(seq_rows(theta), function(s)
    sample(mix_comp, 1, prob = theta[s, ])
  )
}

# extract the first valid predicted value per Stan sample per observation 
# @param rng draws to be check against truncation boundaries
# @param lb vector of lower bounds
# @param ub vector of upper bound
# @return a valid truncated sample or else the closest boundary
extract_valid_sample <- function(rng, lb, ub) {
  valid_rng <- match(TRUE, rng >= lb & rng <= ub)
  if (is.na(valid_rng)) {
    # no valid truncated value found
    # set sample to lb or ub
    # 1e-10 is only to identify the invalid draws later on
    out <- ifelse(max(rng) < lb, lb - 1e-10, ub + 1e-10)
  } else {
    out <- rng[valid_rng]
  }
  out
}

# check for invalid predictions of truncated discrete models
# @param x matrix of predicted values
# @param lb optional lower truncation bound
# @param ub optional upper truncation bound
# @param thres threshold (in %) of invalid values at which to warn the user
# @return rounded values of 'x'
check_discrete_trunc_bounds <- function(x, lb = NULL, ub = NULL, thres = 0.01) {
  if (is.null(lb) && is.null(ub)) {
    return(x)
  }
  if (is.null(lb)) lb <- -Inf
  if (is.null(ub)) ub <- Inf
  thres <- as_one_numeric(thres)
  # ensure correct comparison with vector bounds
  y <- as.vector(t(x))
  pct_invalid <- mean(y < lb | y > ub, na.rm = TRUE)
  if (pct_invalid >= thres) {
    warning2(
      round(pct_invalid * 100), "% of all predicted values ", 
      "were invalid. Increasing argument 'ntrys' may help."
    )
  }
  round(x)
}
