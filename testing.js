export default {
  fetch(request) {
    return new Response("Hello World!", {
      headers: { "content-type": "text/plain" },
    });
  },
};
