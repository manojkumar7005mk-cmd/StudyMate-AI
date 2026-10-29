#include "llama.h"
#include <cstring>
#include <string>
#include <vector>

static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static llama_sampler* g_smpl = nullptr;
static const llama_vocab* g_vocab = nullptr;

static void release_all() {
    if (g_smpl) llama_sampler_free(g_smpl);
    if (g_ctx) llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_smpl = nullptr;
    g_ctx = nullptr;
    g_model = nullptr;
    g_vocab = nullptr;
}

extern "C" {

// Returns 0 on success, -1 model load failed, -2 context failed.
int sm_load(const char* model_path, int n_ctx, int n_threads) {
    release_all();
    llama_backend_init();
    llama_model_params mp = llama_model_default_params();
    g_model = llama_model_load_from_file(model_path, mp);
    if (!g_model) return -1;
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    cp.n_threads = n_threads;
    cp.n_threads_batch = n_threads;
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) return -2;

    g_smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(g_smpl, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(g_smpl, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(g_smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return 0;
}

// Streams each token piece to cb. The prompt is already in ChatML form from Dart.
int sm_generate(const char* prompt, int max_tokens, void (*cb)(const char*)) {
    if (!g_ctx) return -1;
    llama_memory_clear(llama_get_memory(g_ctx), true);
    llama_sampler_reset(g_smpl);

    const int32_t len = (int32_t)strlen(prompt);
    int32_t n = -llama_tokenize(g_vocab, prompt, len, nullptr, 0, true, true);
    if (n <= 0) return -2;
    std::vector<llama_token> toks(n);
    llama_tokenize(g_vocab, prompt, len, toks.data(), n, true, true);

    llama_batch batch = llama_batch_get_one(toks.data(), (int32_t)toks.size());
    for (int i = 0; i < max_tokens; i++) {
        if (llama_decode(g_ctx, batch) != 0) return -3;
        llama_token t = llama_sampler_sample(g_smpl, g_ctx, -1);
        if (llama_vocab_is_eog(g_vocab, t)) break;

        char buf[256];
        int k = llama_token_to_piece(g_vocab, t, buf, sizeof(buf), 0, true);
        if (k > 0) cb(std::string(buf, k).c_str());
        batch = llama_batch_get_one(&t, 1);
    }
    return 0;
}

void sm_free() { release_all(); }

}
