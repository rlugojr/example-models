// Jolly-Seber model as a restricted occupancy model

functions {
  // These functions are derived from Section 12.3 of
  // Stan Modeling Language User's Guide and Reference Manual

  /**
   * Return a integer value of first capture occasion
   *
   * @param y_i Integer array of capture history
   *
   * @return Integer value of first capture occasion
   */
  int first_capture(int[] y_i) {
    for (k in 1:size(y_i))
      if (y_i[k])
        return k;
    return 0;
  }

  /**
   * Return a integer value of last capture occasion
   *
   * @param y_i Integer array of capture history
   *
   * @return Integer value of last capture occasion
   */
  int last_capture(int[] y_i) {
    for (k_rev in 0:(size(y_i) - 1)) {
      int k = size(y_i) - k_rev;

      if (y_i[k])
        return k;
    }
    return 0;
  }

  /**
   * Return a matrix of uncaptured probability
   *
   * @param nind        Number of individuals
   * @param n_occasions Number of capture occasions
   * @param p           Detection probability for each individual
   *                    and capture occasion
   * @param phi         Survival probability for each individual
   *                    and capture occasion
   *
   * @return Uncaptured probability matrix
   */
  matrix prob_uncaptured(int nind, int n_occasions,
                         matrix p, matrix phi) {
    matrix[nind, n_occasions] chi;

    for (i in 1:nind) {
      chi[i, n_occasions] = 1.0;
      for (t in 1:(n_occasions - 1)) {
        int t_curr = n_occasions - t;
        int t_next = t_curr + 1;

        chi[i, t_curr] = (1.0 - phi[i, t_curr])
                        + phi[i, t_curr] * (1.0 - p[i, t_next]) * chi[i, t_next];
      }
    }
    return chi;
  }

  /**
   * Calculate log likelihood of a Jolly-Seber model
   *
   * @param n_ind       Number of individuals
   * @param n_occasions Number of capture occasions
   * @param y           Capture history
   * @param first       First capture occasion
   * @param last        Last capture occasion
   * @param p           Detection probability matrix
   * @param phi         Survival probability matrix
   * @param gamma       Removal entry probability vector
   * @param chi         Uncapture probability matrix
   */
  void jolly_seber_lp(int n_ind, int n_occasions, int[,] y,
                      int[] first, int[] last,
                      matrix p, matrix phi, vector gamma,
                      matrix chi) {
    vector[n_occasions] qgamma = 1.0 - gamma;

    for (i in 1:n_ind) {
      vector[n_occasions] qp = 1.0 - p[i]';

      if (first[i]) { // Captured
        // Until first capture
        if (first[i] == 1) {
          1 ~ bernoulli(gamma[1] * p[i, 1]);
        } else {
          vector[first[i]] lp;

          // Entered at 1st occasion
          lp[1] = bernoulli_lpmf(1 | gamma[1])
                 + bernoulli_lpmf(1 | prod(qp[1:(first[i] - 1)]))
                 + bernoulli_lpmf(1 | prod(phi[i, 1:(first[i] - 1)]))
                 + bernoulli_lpmf(1 | p[i, first[i]]);
          // Entered at t-th occasion (1 < t < first[i])
          for (t in 2:(first[i] - 1))
            lp[t] = bernoulli_lpmf(1 | prod(qgamma[1:(t - 1)]))
                   + bernoulli_lpmf(1 | gamma[t])
                   + bernoulli_lpmf(1 | prod(qp[t:(first[i] - 1)]))
                   + bernoulli_lpmf(1 | prod(phi[i, t:(first[i] - 1)]))
                   + bernoulli_lpmf(1 | p[i, first[i]]);
          lp[first[i]] = bernoulli_lpmf(1 | prod(qgamma[1:(first[i] - 1)]))
                        + bernoulli_lpmf(1 | gamma[first[i]])
                        + bernoulli_lpmf(1 | p[i, first[i]]);
          target += log_sum_exp(lp);
        }
        // Until last capture
        for (t in (first[i] + 1):last[i]) {
          1 ~ bernoulli(phi[i, t - 1]);   // Survived
          y[i, t] ~ bernoulli(p[i, t]);   // Capture/Non-capture
        }
        // Subsequent occasions
        1 ~ bernoulli(chi[i, last[i]]);
      } else {         // Never captured
        vector[n_occasions+1] lp;

        // Entered at 1st occasion, but never captured
        lp[1] = bernoulli_lpmf(1 | gamma[1])
               + bernoulli_lpmf(0 | p[i, 1])
               + bernoulli_lpmf(1 | chi[i, 1]);
        // Entered at t-th occasion, but never captured
        for (t in 2:n_occasions)
          lp[t] = bernoulli_lpmf(1 | prod(qgamma[1:(t - 1)]))
                 + bernoulli_lpmf(1 | gamma[t])
                 + bernoulli_lpmf(0 | p[i, t])
                 + bernoulli_lpmf(1 | chi[i, t]);
        // Never entered
        lp[n_occasions + 1] = bernoulli_lpmf(1 | prod(qgamma));
        target += log_sum_exp(lp);
      }
    }
  }
}

data {
  int<lower=0> M;                              // Augmented sample size
  int<lower=0> n_occasions;                    // Number of capture occasions
  int<lower=0,upper=1> y[M, n_occasions];      // Augmented capture-history
}

transformed data {
  int<lower=0,upper=n_occasions> first[M];
  int<lower=0,upper=n_occasions> last[M];

  for (i in 1:M)
    first[i] = first_capture(y[i]);
  for (i in 1:M)
    last[i] = last_capture(y[i]);
}

parameters {
  real<lower=0,upper=1> mean_phi;             // Mean survival
  real<lower=0,upper=1> mean_p;               // Mean capture
  vector<lower=0,upper=1>[n_occasions] gamma; // Removal entry probability
  vector[n_occasions-1] epsilon;
  real<lower=0,upper=5> sigma;
  // In case of using a weakly informative prior
  //  real<lower=0> sigma;
}

transformed parameters {
  matrix<lower=0,upper=1>[M, n_occasions - 1] phi;
  matrix<lower=0,upper=1>[M, n_occasions] p;
  matrix<lower=0,upper=1>[M, n_occasions] chi;

  // Constraints
  for (i in 1:M) {
    for (t in 1:(n_occasions - 1))
      phi[i, t] = inv_logit(logit(mean_phi) + epsilon[t]);
    for (t in 1:n_occasions)
      p[i, t] = mean_p;
  }

  // Uncaptured probability
  chi = prob_uncaptured(M, n_occasions, p, phi);
}

model {
  // Priors
  // Uniform priors are implicitly defined.
  //  mean_phi ~ uniform(0, 1);
  //  mean_p ~ uniform(0, 1);
  //  gamma ~ uniform(0, 1);
  //  sigma ~ uniform(0, 5);
  // In case of using a weakly informative prior
  //  sigma ~ normal(2.5, 1.25);
  epsilon ~ normal(0, sigma);

  // Likelihood
  jolly_seber_lp(M, n_occasions, y, first, last,
                 p, phi, gamma, chi);
}

generated quantities {
  real sigma2;
  real psi;                // Inclusion probability
  real b[n_occasions];     // Entry probability
  int Nsuper;              // Superpopulation size
  int N[n_occasions];      // Actual population size
  int B[n_occasions];      // Number of entries
  int z[M, n_occasions];   // Latent state

  // Generate z[]
  for (i in 1:M) {
    int q[n_occasions - 1];
    real mu2;

    z[i, 1] = bernoulli_rng(gamma[1]);
    for (t in 2:n_occasions) {
      q[t - 1] = 1 - z[i, t - 1];
      mu2 = phi[i, t - 1] * z[i, t - 1]
        + gamma[t] * prod(q[1:(t - 1)]);
      z[i, t] = bernoulli_rng(mu2);
    }
  }

  // Calculate derived population parameters
  {
    real qgamma[n_occasions - 1];
    real cprob[n_occasions];
    int recruit[M, n_occasions];
    int Nind[M];
    int Nalive[M];

    sigma2 = sigma^2;
    for (t in 1:n_occasions - 1)
      qgamma[t] = 1 - gamma[t];
    cprob[1] = gamma[1];
    for (t in 2:n_occasions)
      cprob[t] = gamma[t] * prod(qgamma[1:(t - 1)]);
    psi = sum(cprob);
    for (t in 1:n_occasions)
      b[t] = cprob[t] / psi;
    for (i in 1:M) {
      recruit[i, 1] = z[i, 1];
      for (t in 2:n_occasions) {
        recruit[i, t] = (1 - z[i, t - 1]) * z[i, t];
      }
    }
    for (t in 1:n_occasions) {
      N[t] = sum(z[, t]);
      B[t] = sum(recruit[, t]);
    }
    for (i in 1:M) {
      Nind[i] = sum(z[i]);
      Nalive[i] = (Nind[i] > 0);
    }
    Nsuper = sum(Nalive);
  }
}
